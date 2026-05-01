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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        methodChannel?.setMethodCallHandler { call, result ->
            if (call.method == "anchorModel") {
                val lat = call.argument<Double>("lat")
                val lng = call.argument<Double>("lng")
                val assetPath = call.argument<String>("assetPath")
                Log.d("MainActivity", "Received anchorModel: lat=\$lat, lng=\$lng, assetPath=\$assetPath")
                
                // Scaffold Earth anchor logic
                try {
                    // Send initial state
                    methodChannel?.invokeMethod("onTrackingStateChanged", "LOCALIZING")
                    
                    val earth = arSession?.earth
                    if (earth?.trackingState == TrackingState.TRACKING) {
                        val altitude = 0.0
                        val anchor = earth.createAnchor(lat!!, lng!!, altitude, 0f, 0f, 0f, 1f)
                        Log.d("MainActivity", "Earth anchor created at \$lat, \$lng")
                        methodChannel?.invokeMethod("onTrackingStateChanged", "TRACKING")
                        result.success(true)
                    } else {
                        Log.w("MainActivity", "Earth API not tracking yet.")
                        
                        // POC Simulation: Simulate acquiring tracking after 3 seconds for UI demonstration
                        Handler(Looper.getMainLooper()).postDelayed({
                            methodChannel?.invokeMethod("onTrackingStateChanged", "TRACKING")
                        }, 3000)
                        
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
}
