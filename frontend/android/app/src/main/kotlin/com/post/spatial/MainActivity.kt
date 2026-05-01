package com.post.spatial

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.postspatial.ar/geospatial"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "anchorModel") {
                val lat = call.argument<Double>("lat")
                val lng = call.argument<Double>("lng")
                val assetPath = call.argument<String>("assetPath")
                Log.d("MainActivity", "Received anchorModel: lat=\$lat, lng=\$lng, assetPath=\$assetPath")
                result.success(true)
            } else {
                result.notImplemented()
            }
        }
    }
}
