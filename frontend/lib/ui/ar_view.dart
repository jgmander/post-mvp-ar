import 'package:flutter/material.dart';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../models/post.dart';
import 'create_post_view.dart';

class ArView extends StatefulWidget {
  @override
  _ArViewState createState() => _ArViewState();
}

class _ArViewState extends State<ArView> {
  late ArCoreController arCoreController;
  final ApiService _apiService = ApiService();
  List<Post> nearbyPosts = [];

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndFetchPosts();
  }

  Future<void> _checkPermissionsAndFetchPosts() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    Position position = await Geolocator.getCurrentPosition();
    try {
      final posts = await _apiService.getNearbyPosts(position.latitude, position.longitude);
      setState(() {
        nearbyPosts = posts;
      });
    } catch (e) {
      print("Failed to fetch posts: $e");
    }
  }

  void onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;
    
    // In a full production app, we would use the Geospatial API to anchor these
    // nodes to precise real-world coordinates. For this MVP mockup code, we place
    // them relatively around the user's start position using ArCoreNode.
    
    for (var post in nearbyPosts) {
      // Create a basic visual node for the post
      final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
      final sphere = ArCoreSphere(materials: [material], radius: 0.2);
      
      // We place them arbitrarily in front of the user for MVP testing if GPS is close
      final node = ArCoreNode(
        shape: sphere,
        position: vector.Vector3(0, 0, -1.5), 
      );
      
      arCoreController.addArCoreNode(node);
    }
  }

  @override
  void dispose() {
    arCoreController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Post AR World')),
      body: Stack(
        children: [
          ArCoreView(
            onArCoreViewCreated: onArCoreViewCreated,
            enableTapRecognizer: true,
          ),
          Positioned(
            bottom: 30,
            right: 30,
            child: FloatingActionButton(
              child: Icon(Icons.add),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => CreatePostView()),
                ).then((_) => _checkPermissionsAndFetchPosts());
              },
            ),
          )
        ],
      ),
    );
  }
}
