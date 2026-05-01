package com.post.spatial

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Session
import com.google.ar.core.Earth
import com.google.ar.core.TrackingState

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.postspatial.ar/geospatial"
    private var arSession: Session? = null // Scaffolded session reference

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "anchorModel") {
                val lat = call.argument<Double>("lat")
                val lng = call.argument<Double>("lng")
                val assetPath = call.argument<String>("assetPath")
                Log.d("MainActivity", "Received anchorModel: lat=\$lat, lng=\$lng, assetPath=\$assetPath")
                
                // Scaffold Earth anchor logic
                try {
                    val earth = arSession?.earth
                    if (earth?.trackingState == TrackingState.TRACKING) {
                        // In a real app, altitude would be retrieved via earth.cameraGeospatialPose.altitude
                        val altitude = 0.0
                        val anchor = earth.createAnchor(lat!!, lng!!, altitude, 0f, 0f, 0f, 1f)
                        Log.d("MainActivity", "Earth anchor created at \$lat, \$lng")
                        
                        // Scaffold rendering logic using Sceneform/Filament
                        // loadModelAsync(assetPath, anchor)
                        result.success(true)
                    } else {
                        Log.w("MainActivity", "Earth API not tracking yet.")
                        result.success(false) // POC mock success/fail
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
}
