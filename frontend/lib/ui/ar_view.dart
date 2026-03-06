import 'dart:async';
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
  Timer? _vpsTimer;
  Map<String, dynamic>? _currentPose;
  bool _isAuraTargetingBuilding = false;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndFetchPosts();
    _vpsTimer = Timer.periodic(Duration(seconds: 1), (_) => _updateVPS());
  }

  Future<void> _updateVPS() async {
    if (_arCoreInitialized) {
      final pose = await arCoreController.getGeospatialPose();
      if (mounted) {
        setState(() {
          _currentPose = pose;
        });
        if (pose != null && pose['accuracy'] < 1.0) {
          // Once tracking is strong enough, render posts if they were waiting.
          _renderPosts();
        }
      }
    }
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
    
    if (permission == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Location permissions are permanently denied, we cannot request permissions. Earth Anchors require Location.')));
      return;
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
    arCoreController.onRooftopAnchorResolved = _handleRooftopAnchorResolved;
    arCoreController.onCenterHitBuilding = _handleCenterHitBuilding;
    _arCoreInitialized = true;
    
    // Resume immediately to fix black screen bug where Android misses the onResume hook.
    arCoreController.resume();
    
    _renderPosts();
  }

  void _handleCenterHitBuilding(bool isBuilding) {
    if (_isAuraTargetingBuilding != isBuilding && mounted) {
      setState(() {
        _isAuraTargetingBuilding = isBuilding;
      });
    }
  }

  void _handleRooftopAnchorResolved(String name, bool success, String? state) {
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✨ Precision Rooftop Anchor Locked!')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rooftop Anchor failed: \$state. Make sure you are pointing at a building.')));
    }
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

  void _handleOnPlaneTap(List<ArCoreHitTestResult> hits) async {
    if (hits.isNotEmpty) {
      final hit = hits.first;
      
      final acc = _currentPose != null ? _currentPose!['accuracy'] : 999.0;
      if (acc > 3.0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('VPS Signal too weak (${acc.toStringAsFixed(1)}m > 3.0m). Please look around at buildings to localize.')));
        return;
      }

      String placeName = "Unknown Location";
      String placeCategory = "Unknown";
      
      if (hit.hitLat != null && hit.hitLng != null) {
         final placeData = await _apiService.getPlaceFromCoordinates(hit.hitLat!, hit.hitLng!);
         if (placeData != null) {
            placeName = placeData['name'] ?? placeName;
            placeCategory = placeData['category'] ?? placeCategory;
         }
      }

      _showCreatePostBottomSheet(hit, placeName, placeCategory);
    }
  }

  void _showCreatePostBottomSheet(ArCoreHitTestResult hit, String placeName, String placeCategory) {
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
                  Text("Pin to: \$placeName", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.blueAccent), textAlign: TextAlign.center),
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
                              // Use exact hit mesh lat/lng if available, fallback to camera pose
                              final lat = hit.hitLat ?? _currentPose!['latitude'] as double;
                              final lng = hit.hitLng ?? _currentPose!['longitude'] as double;
                              final alt = hit.hitAlt ?? _currentPose!['altitude'] as double;

                              final newPost = Post(
                                latitude: lat,
                                longitude: lng,
                                altitude: alt,
                                messageContent: _contentController.text,
                                creatorId: 'user_123',
                                visibilityType: _visibilityType,
                                reach: 50,
                                placeName: placeName,
                                placeCategory: placeCategory,
                              );

                              final created = await _apiService.createPost(newPost);
                              
                              final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
                              final sphere = ArCoreSphere(materials: [material], radius: 0.2);
                              final node = ArCoreNode(
                                name: created.id ?? "temp_\${DateTime.now().millisecondsSinceEpoch}",
                                shape: sphere,
                                position: hit.pose.translation,
                              );
                              
                              if (_visibilityType == '1-to-many') {
                                // 1-to-many posts pin to Rooftops using Streetscape Geometry.
                                // We pass 0.5m so it hovers slightly above the detected roof.
                                await arCoreController.resolveAnchorOnRooftopAsync(node, lat, lng, 0.5);
                              } else {
                                // 1-to-1 uses absolute physical altitude from the camera pose
                                await arCoreController.addEarthAnchorNode(node, lat, lng, alt);
                              }
                              
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

      final node = ArCoreNode(
        name: postId,
        shape: sphere,
      );
      
      // Anchoring them directly using precise Earth GPS coordinates
      arCoreController.addEarthAnchorNode(node, post.latitude, post.longitude, post.altitude ?? 0.0);
      index++;
    }
  }

  @override
  void dispose() {
    _vpsTimer?.cancel();
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
                debug: true,
              ),
              if (_isAuraTargetingBuilding)
                IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Colors.cyanAccent.withOpacity(0.4),
                        width: 4,
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.cyanAccent, width: 2),
                          boxShadow: [
                            BoxShadow(color: Colors.cyanAccent.withOpacity(0.4), blurRadius: 30, spreadRadius: 15)
                          ]
                        ),
                        child: Center(child: Icon(Icons.add, color: Colors.cyanAccent, size: 30)),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 40,
                left: 20,
                right: 20,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: (_currentPose != null && _currentPose!['accuracy'] < 3.0) 
                        ? Colors.green.withOpacity(0.8) 
                        : Colors.red.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _currentPose == null 
                        ? "VPS Connecting..." 
                        : "VPS Signal: ${_currentPose!['accuracy'].toStringAsFixed(2)}m\nPoint at surface & tap dots to pin.",
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            ],
          ),
    );
  }
}
