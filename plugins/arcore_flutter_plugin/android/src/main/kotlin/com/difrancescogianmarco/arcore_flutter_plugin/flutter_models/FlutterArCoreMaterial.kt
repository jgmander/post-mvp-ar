package com.difrancescogianmarco.arcore_flutter_plugin.flutter_models

import android.graphics.Color
import androidx.annotation.ColorInt
import androidx.annotation.IntRange

class FlutterArCoreMaterial(map: HashMap<String, *>) {

    val argb: ArrayList<Int>? = map["color"] as? ArrayList<Int>
    @field:ColorInt var color: Int = getIntColor(argb) ?: DEFAULT_COLOR
    @field:IntRange(from = 0, to = 100) var metallic: Int = parsePercent(map["metallic"], DEFAULT_METALLIC)
    @field:IntRange(from = 0, to = 100) var roughness: Int = parsePercent(map["roughness"], DEFAULT_ROUGHNESS)
    @field:IntRange(from = 0, to = 100) var reflectance: Int = parsePercent(map["reflectance"], DEFAULT_REFLECTANCE)
    val textureBytes: ByteArray? = map["textureBytes"] as? ByteArray

    companion object {

        private const val DEFAULT_COLOR = Color.WHITE
        private const val DEFAULT_METALLIC = 0
        private const val DEFAULT_ROUGHNESS = 22
        private const val DEFAULT_REFLECTANCE = 80

        val DEFAULT = FlutterArCoreMaterial(HashMap<String, Any>())

        private fun parsePercent(raw: Any?, fallback: Int): Int {
            if (raw is Number) {
                val d = raw.toDouble()
                return if (d in 0.0..1.0) Math.round(d * 100.0).toInt() else d.toInt().coerceIn(0, 100)
            }
            return fallback
        }
    }
    
    private fun getIntColor(argb: ArrayList<Int>?): Int? {
        if (argb != null) {
            return Color.argb(argb[0], argb[1], argb[2], argb[3])
        }
        return null
    }

    override fun toString(): String {
        return "color: $color\nargb: $argb\n" +
                "textureBytesLength: ${textureBytes?.size}\n" +
                "metallic: $metallic\n" +
                "roughness: $roughness\n" +
                "reflectance: $reflectance"
    }
}