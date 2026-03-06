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
  bool _isReady = false;
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

    Position? position;
    try {
      // First try to get cached position for instant loading
      position = await Geolocator.getLastKnownPosition();
      
      // If no cache, try a quick low-accuracy fetch so it doesn't hang indoors
      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
        timeLimit: const Duration(seconds: 4),
      );
    } catch (e) {
      print("Geolocation timeout or error indoors: \$e");
      // Fallback to the user's hardcoded test location (Floral Park) if GPS is fully blocked indoors
      position = Position(
        latitude: 40.723000,
        longitude: -73.705200,
        timestamp: DateTime.now(),
        accuracy: 100,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );
    }
    try {
      final posts = await _apiService.getNearbyPosts(position.latitude, position.longitude);
      setState(() {
        nearbyPosts = posts;
        _isReady = true;
      });
      _renderPosts();
    } catch (e) {
      print("Failed to fetch posts: $e");
      setState(() {
        _isReady = true; // Proceed anyway so they can at least place a new post
      });
    }
  }

  void onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;
    arCoreController.onNodeTap = (name) => _handleOnNodeTap(name);
    arCoreController.onPlaneTap = _handleOnPlaneTap;
    _arCoreInitialized = true;
    
    // Resume immediately to fix black screen bug where Android misses the onResume hook.
    arCoreController.resume();
    
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

  void _handleOnPlaneTap(List<ArCoreHitTestResult> hits) {
    if (hits.isNotEmpty) {
      final hit = hits.first;
      _showCreatePostBottomSheet(hit.pose.translation);
    }
  }

  void _showCreatePostBottomSheet(vector.Vector3 localPosition) {
    final _contentController = TextEditingController();
    String _visibilityType = '1-to-many';
    bool _isSubmitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 24,
                right: 24,
                top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Pin a New Post", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  SizedBox(height: 20),
                  TextField(
                    controller: _contentController,
                    decoration: InputDecoration(
                      labelText: 'Message Content',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    maxLines: 3,
                  ),
                  SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: _visibilityType,
                    items: ['1-to-1', '1-to-many'].map((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setModalState(() => _visibilityType = val);
                    },
                    decoration: InputDecoration(
                      labelText: 'Visibility',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  SizedBox(height: 24),
                  _isSubmitting
                      ? CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: () async {
                            if (_contentController.text.isEmpty) return;
                            setModalState(() => _isSubmitting = true);
                            
                            try {
                              Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
                              
                              final newPost = Post(
                                latitude: position.latitude,
                                longitude: position.longitude,
                                altitude: position.altitude,
                                messageContent: _contentController.text,
                                creatorId: 'user_123',
                                visibilityType: _visibilityType,
                                reach: 50,
                              );

                              final created = await _apiService.createPost(newPost);
                              
                              final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
                              final sphere = ArCoreSphere(materials: [material], radius: 0.2);
                              final node = ArCoreNode(
                                name: created.id ?? "temp_${DateTime.now().millisecondsSinceEpoch}",
                                shape: sphere,
                                position: localPosition,
                              );
                              arCoreController.addArCoreNode(node);
                              
                              setState(() {
                                nearbyPosts.add(created);
                                _renderedPostIds.add(node.name!);
                              });
                              
                              Navigator.pop(context);
                              
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Post Pinned! CTA: ${created.ctaText ?? 'None'}')),
                              );
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                              setModalState(() => _isSubmitting = false);
                            }
                          },
                          child: Text('Drop Pin Here', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            minimumSize: Size.fromHeight(54),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                  SizedBox(height: 30),
                ],
              ),
            );
          },
        );
      },
    );
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
      body: !_isReady 
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text("Acquiring GPS and checking surroundings..."),
              ],
            ),
          )
        : Stack(
            children: [
              ArCoreView(
                onArCoreViewCreated: onArCoreViewCreated,
                enableTapRecognizer: true,
              ),
              Positioned(
                top: 40,
                left: 20,
                right: 20,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    "Point at a surface and tap the white dots to drop a pin.",
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            ],
          ),
    );
  }
}
