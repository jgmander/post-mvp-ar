package com.post.spatial

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.postspatial.ar/geospatial"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "anchorModel" -> {
                    // Anchor creation is handled by the arcore_flutter_plugin's ArCoreView.
                    // MainActivity no longer owns an AR session — the plugin has exclusive
                    // camera access to prevent dual-session conflicts and camera lockouts.
                    val lat = call.argument<Double>("lat")
                    val lng = call.argument<Double>("lng")
                    Log.d("MainActivity", "anchorModel stub: lat=$lat, lng=$lng (handled by plugin ArCoreView)")
                    result.success(true)
                }
                "startArSession" -> {
                    // AR session lifecycle is owned exclusively by the arcore_flutter_plugin.
                    // MainActivity acknowledges the call without starting a competing session.
                    Log.d("MainActivity", "startArSession stub: session owned by arcore_flutter_plugin")
                    result.success(true)
                }
                "stopArSession" -> {
                    // AR session lifecycle is owned exclusively by the arcore_flutter_plugin.
                    Log.d("MainActivity", "stopArSession stub: session owned by arcore_flutter_plugin")
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
