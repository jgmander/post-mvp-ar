package com.post.spatial

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Session
import com.google.ar.core.Earth
import com.google.ar.core.TrackingState
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.postspatial.ar/geospatial"
    private var arSession: Session? = null // Scaffolded session reference
    private var methodChannel: MethodChannel? = null
    
    // Live Tracking State Cache
    private var lastTrackingState: TrackingState? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    
    // Equivalent Session Frame Listener (Live Binding)
    private val trackingStatePoller = object : Runnable {
        override fun run() {
            val earth = arSession?.earth
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
                    if (earth?.trackingState == TrackingState.TRACKING) {
                        val altitude = 0.0
                        val anchor = earth.createAnchor(lat!!, lng!!, altitude, 0f, 0f, 0f, 1f)
                        Log.d("MainActivity", "Earth anchor created at \$lat, \$lng")
                        result.success(true)
                    } else {
                        Log.w("MainActivity", "Earth API not tracking yet. Live binding active.")
                        result.success(false) 
                    }
                } catch (e: Exception) {
                    Log.e("MainActivity", "Error creating Earth anchor", e)
                    result.error("ANCHOR_ERROR", e.localizedMessage, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
    
    override fun onDestroy() {
        mainHandler.removeCallbacks(trackingStatePoller)
        super.onDestroy()
    }
}
