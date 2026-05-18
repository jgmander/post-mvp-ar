class EnvConfig {
  static const String mapId = String.fromEnvironment('MAP_ID', defaultValue: '1bf9740a3948b26976700a08');
  static const String iosMapId = String.fromEnvironment('IOS_MAP_ID', defaultValue: '1bf9740a3948b2695b963ae7');

  static void validate() {
    if (mapId.isEmpty || iosMapId.isEmpty) {
      throw Exception("CRITICAL: Vector Map IDs missing. Check --dart-define pipeline.");
    }
  }
}
