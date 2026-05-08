package com.post.spatial

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.ar.core.Session
import com.google.ar.core.Config
import com.google.ar.core.TrackingState
import com.google.ar.core.Earth
import com.google.ar.core.exceptions.UnavailableApkTooOldException
import com.google.ar.core.exceptions.UnavailableArcoreNotInstalledException
import com.google.ar.core.exceptions.UnavailableDeviceNotCompatibleException
import com.google.ar.core.exceptions.UnavailableSdkTooOldException
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException
import com.google.ar.core.StreetscapeGeometry

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.postspatial.ar/geospatial"
    private var arSession: Session? = null
    private var methodChannel: MethodChannel? = null
    private var isArEnabled = false
    
    // Live Tracking State Cache
    private var lastTrackingState: TrackingState? = null
    private var lastEarthState: com.google.ar.core.Earth.EarthState? = null
    private var lastFrame: com.google.ar.core.Frame? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Equivalent Session Frame Listener (Live Binding)
    private val trackingStatePoller = object : Runnable {
        override fun run() {
            try {
                lastFrame = arSession?.update()
            } catch (e: Exception) {
                // Ignore update errors in this POC headless poller
            }

            val earth = arSession?.earth
            
            // EarthState Telemetry
            val currentEarthState = earth?.earthState
            if (currentEarthState != null && currentEarthState != lastEarthState) {
                lastEarthState = currentEarthState
                Log.d("ARCore-Earth", "Live EarthState: \$currentEarthState")
            }

            val currentState = earth?.trackingState
            if (currentState != null && currentState != lastTrackingState) {
                lastTrackingState = currentState
                val stateString = when (currentState) {
                    TrackingState.TRACKING -> "TRACKING"
                    TrackingState.PAUSED -> "LOCALIZING"
                    TrackingState.STOPPED -> "NOT_AVAILABLE"
                    else -> "UNKNOWN"
                }
                Log.d("MainActivity", "Live Tracking State Transitioned: \$stateString")
                methodChannel?.invokeMethod("onTrackingStateChanged", stateString)
            }
            
            // Re-queue the equivalent frame listener to query next frame
            mainHandler.postDelayed(this, 100)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "anchorModel") {
                val lat = call.argument<Double>("lat")
                val lng = call.argument<Double>("lng")
                val assetPath = call.argument<String>("assetPath")
                Log.d("MainActivity", "Received anchorModel: lat=\$lat, lng=\$lng, assetPath=\$assetPath")
                
                // Bind the live tracking loop
                lastTrackingState = null
                methodChannel?.invokeMethod("onTrackingStateChanged", "LOCALIZING")
                mainHandler.post(trackingStatePoller)
                
                // Scaffold Earth anchor logic
                try {
                    val earth = arSession?.earth
                    val frame = lastFrame
                    if (earth?.trackingState == TrackingState.TRACKING && frame != null) {
                        val altitude = earth.cameraGeospatialPose.altitude
                        val tempAnchor = earth.createAnchor(lat!!, lng!!, altitude, 0f, 0f, 0f, 1f)
                        val tempPose = tempAnchor.pose
                        val cameraPose = frame.camera.pose
                        
                        val dx = tempPose.tx() - cameraPose.tx()
                        val dy = tempPose.ty() - cameraPose.ty()
                        val dz = tempPose.tz() - cameraPose.tz()
                        val distance = Math.sqrt((dx * dx + dy * dy + dz * dz).toDouble()).toFloat()
                        
                        val origin = floatArrayOf(cameraPose.tx(), cameraPose.ty(), cameraPose.tz())
                        val direction = floatArrayOf(dx / distance, dy / distance, dz / distance)
                        
                        val hitResults = frame.hitTest(origin, 0, direction, 0)
                        var hitBuilding = false
                        var hitPose: com.google.ar.core.Pose? = null
                        
                        for (hit in hitResults) {
                            val trackable = hit.trackable
                            if (trackable is StreetscapeGeometry && trackable.type == StreetscapeGeometry.Type.BUILDING) {
                                hitBuilding = true
                                hitPose = hit.hitPose
                                break
                            }
                        }
                        
                        if (hitBuilding && hitPose != null) {
                            val finalAnchor = arSession?.createAnchor(hitPose)
                            Log.d("MainActivity", "Snapped to BUILDING mesh at \${hitPose.tx()}, \${hitPose.ty()}, \${hitPose.tz()}")
                            tempAnchor.detach()
                            result.success(true)
                        } else {
                            Log.d("MainActivity", "Earth anchor created at \$lat, \$lng (No building hit)")
                            result.success(true)
                        }
                    } else {
                        Log.w("MainActivity", "Earth API not tracking yet. Live binding active.")
                        result.success(false) 
                    }
                } catch (e: Exception) {
                    Log.e("MainActivity", "Error creating Earth anchor", e)
                    result.error("ANCHOR_ERROR", e.localizedMessage, null)
                }
            } else if (call.method == "startArSession") {
                isArEnabled = true
                startArSessionInternal()
                result.success(true)
            } else if (call.method == "stopArSession") {
                isArEnabled = false
                stopArSessionInternal()
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun startArSessionInternal() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA, Manifest.permission.ACCESS_FINE_LOCATION),
                1
            )
            return
        }
        
        if (arSession == null) {
            try {
                arSession = Session(this)
                val config = Config(arSession)
                config.geospatialMode = Config.GeospatialMode.ENABLED
                config.streetscapeGeometryMode = Config.StreetscapeGeometryMode.ENABLED
                arSession?.configure(config)
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to create AR session", e)
            }
        }

        try {
            arSession?.resume()
        } catch (e: Exception) {
            Log.e("MainActivity", "Failed to resume AR session", e)
        }
    }

    private fun stopArSessionInternal() {
        mainHandler.removeCallbacks(trackingStatePoller)
        arSession?.pause()
        arSession?.close()
        arSession = null
    }

    override fun onResume() {
        super.onResume()
        if (isArEnabled) {
            startArSessionInternal()
        }
    }

    override fun onPause() {
        super.onPause()
        arSession?.pause()
    }
    
    override fun onDestroy() {
        mainHandler.removeCallbacks(trackingStatePoller)
        arSession?.close()
        super.onDestroy()
    }
}
