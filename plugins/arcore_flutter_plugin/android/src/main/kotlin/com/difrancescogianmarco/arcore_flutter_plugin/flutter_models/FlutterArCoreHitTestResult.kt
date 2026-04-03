package com.difrancescogianmarco.arcore_flutter_plugin.flutter_models

class FlutterArCoreHitTestResult(
    val distance: Float, 
    val translation: FloatArray, 
    val rotation: FloatArray, 
    val nodeType: String? = null,
    val hitLat: Double? = null,
    val hitLng: Double? = null,
    val hitAlt: Double? = null
) {

    fun toHashMap(): HashMap<String, Any> {
        val map: HashMap<String, Any> = HashMap<String, Any>()
        map["distance"] = distance.toDouble()
        map["pose"] = FlutterArCorePose(translation,rotation).toHashMap()
        if (nodeType != null) {
            map["nodeType"] = nodeType
        }
        if (hitLat != null) {
            map["hitLat"] = hitLat
        }
        if (hitLng != null) {
            map["hitLng"] = hitLng
        }
        if (hitAlt != null) {
            map["hitAlt"] = hitAlt
        }
        return map
    }
}