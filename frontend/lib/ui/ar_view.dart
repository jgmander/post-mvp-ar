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
  bool _arCoreInitialized = false;
  Set<String> _renderedPostIds = {};

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
      _renderPosts();
    } catch (e) {
      print("Failed to fetch posts: $e");
    }
  }

  void onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;
    arCoreController.onNodeTap = (name) => _handleOnNodeTap(name);
    _arCoreInitialized = true;
    _renderPosts();
  }

  void _handleOnNodeTap(String name) {
    try {
      final post = nearbyPosts.firstWhere((p) {
        int index = nearbyPosts.indexOf(p);
        String postId = p.id ?? "temp_$index";
        return postId == name;
      });
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Digital Imprint'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(post.messageContent, style: TextStyle(fontSize: 18)),
              if (post.ctaText != null && post.ctaText!.isNotEmpty) ...[
                SizedBox(height: 20),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Action Selected: ${post.ctaText}')),
                    );
                  },
                  style: ElevatedButton.styleFrom(minimumSize: Size.fromHeight(40)),
                  child: Text(post.ctaText!),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      print("Node not found: $name");
    }
  }

  void _renderPosts() {
    if (!_arCoreInitialized) return;
    
    // In a full production app, we would use the Geospatial API to anchor these
    // nodes to precise real-world coordinates. For this MVP mockup code, we place
    // them relatively around the user's start position.
    
    int index = 0;
    for (var post in nearbyPosts) {
      String postId = post.id ?? "temp_${index}";
      if (_renderedPostIds.contains(postId)) {
        index++;
        continue;
      }
      
      _renderedPostIds.add(postId);
      
      // Create a basic visual node for the post
      final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
      final sphere = ArCoreSphere(materials: [material], radius: 0.2);
      
      // We place them arbitrarily in front of the user for MVP testing if GPS is close
      // Scatter them slightly based on index
      double xOffset = (index % 3 - 1) * 0.5; // -0.5, 0, 0.5
      double zOffset = -1.5 - (index / 3) * 0.5;

      final node = ArCoreNode(
        name: postId,
        shape: sphere,
        position: vector.Vector3(xOffset, 0, zOffset), 
      );
      
      arCoreController.addArCoreNode(node);
      index++;
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
