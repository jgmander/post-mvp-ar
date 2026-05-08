import 'package:flutter/material.dart';
import 'package:google_maps_flutter_android/google_maps_flutter_android.dart';
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart';
import 'screens/map_screen.dart';
import 'config/env_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Fail Loudly configuration check
  EnvConfig.validate();

  // ── Vector Renderer Opt-In ──────────────────────────────────────────────
  // Forces the GMS Maps SDK to boot the modern Vector rendering pipeline
  // instead of the Legacy TextureView raster engine. Required for:
  //   • 3D building extrusions (buildingsEnabled: true)
  //   • Proper style layer isolation (geometry overrides don't flatten meshes)
  //   • Better GPU throughput at zoom: 19.5 / tilt: 45.0
  final GoogleMapsFlutterPlatform mapsImpl = GoogleMapsFlutterPlatform.instance;
  if (mapsImpl is GoogleMapsFlutterAndroid) {
    mapsImpl.useAndroidViewSurface = false;
    mapsImpl.initializeWithRenderer(AndroidMapRenderer.latest);
  }

  runApp(PostApp());
}

class PostApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Post',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: MapScreen(),
    );
  }
}
