class EnvConfig {
  static const String mapId = String.fromEnvironment('MAP_ID');
  static const String iosMapId = String.fromEnvironment('IOS_MAP_ID');

  static void validate() {
    if (mapId.isEmpty || iosMapId.isEmpty) {
      throw Exception("CRITICAL: Vector Map IDs missing. Check --dart-define pipeline.");
    }
  }
}
