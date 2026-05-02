import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../models/post.dart';
import 'ar_reveal_screen.dart';

class MapScreen extends StatefulWidget {
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final ApiService _apiService = ApiService();
  GoogleMapController? _mapController;
  final LatLng _initialPosition = const LatLng(40.7251, -73.7055);
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  bool _locationGranted = false;

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndCenter();
  }

  Future<void> _requestPermissionsAndCenter() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        if (mounted) setState(() => _locationGranted = true);
        
        Position? cached = await Geolocator.getLastKnownPosition();
        if (cached != null) {
          _animateToPosition(cached);
          _fetchProperties(cached.latitude, cached.longitude);
        }

        Position precise = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
        );
        _animateToPosition(precise);
        _fetchProperties(precise.latitude, precise.longitude);
      } else {
        // Fallback fetch if permission denied
        _fetchProperties(_initialPosition.latitude, _initialPosition.longitude);
      }
    } catch (e) {
      print("Location permission or fetch failed: $e");
      _fetchProperties(_initialPosition.latitude, _initialPosition.longitude);
    }
  }

  void _animateToPosition(Position pos) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(pos.latitude, pos.longitude),
          zoom: 19.0,
          tilt: 45.0,
        ),
      ),
    );
  }

  Future<void> _fetchProperties(double lat, double lng) async {
    try {
      final posts = await _apiService.getNearbyPosts(lat, lng, radiusKm: 10.0);
      Set<Marker> newMarkers = {};
      Set<Circle> newCircles = {};
      
      List<List<Post>> clusters = [];
      for (var p in posts) {
        bool clustered = false;
        for (var cluster in clusters) {
          final center = cluster.first;
          double distance = Geolocator.distanceBetween(
              center.latitude, center.longitude, p.latitude, p.longitude);
          if (distance <= 8.0) {
            cluster.add(p);
            clustered = true;
            break;
          }
        }
        if (!clustered) {
          clusters.add([p]);
        }
      }

      for (var cluster in clusters) {
        final centerPost = cluster.first;
        final centerLatLng = LatLng(centerPost.latitude, centerPost.longitude);

        newMarkers.add(
          Marker(
            markerId: MarkerId(centerPost.id ?? "cluster_${centerPost.latitude}_${centerPost.longitude}"),
            position: centerLatLng,
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
            onTap: () {
              _showPropertyBottomSheet(cluster);
            },
          ),
        );

        newCircles.add(
          Circle(
            circleId: CircleId(centerPost.id ?? "circle_${centerPost.latitude}_${centerPost.longitude}"),
            center: centerLatLng,
            radius: 15.0,
            fillColor: Colors.blueAccent.withOpacity(0.2),
            strokeColor: Colors.blueAccent,
            strokeWidth: 2,
          ),
        );
      }

      if (mounted) {
        setState(() {
          _markers = newMarkers;
          _circles = newCircles;
        });
      }
    } catch (e) {
      print("Failed to fetch properties: $e");
    }
  }

  void _showPropertyBottomSheet(List<Post> cluster) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        int _currentPage = 0;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 160,
                    child: PageView.builder(
                      itemCount: cluster.length,
                      onPageChanged: (int index) {
                        setModalState(() {
                          _currentPage = index;
                        });
                      },
                      itemBuilder: (context, index) {
                        final p = cluster[index];
                        Map<String, dynamic> propertyData = {
                          'id': p.id ?? '',
                          'lat': p.latitude,
                          'lng': p.longitude,
                          'price': p.messageContent,
                        };
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              p.messageContent,
                              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: () {
                                Navigator.pop(context); // Close bottom sheet
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ArRevealScreen(propertyData: propertyData),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.view_in_ar, size: 24, color: Colors.white),
                              label: const Text('View in AR', style: TextStyle(fontSize: 18, color: Colors.white)),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                backgroundColor: Colors.blueAccent,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  if (cluster.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          cluster.length,
                          (index) => Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4.0),
                            width: 8.0,
                            height: 8.0,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _currentPage == index
                                  ? Colors.blueAccent
                                  : Colors.grey.shade400,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _handleMapTap(LatLng coord) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(coord.latitude, coord.longitude);
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        bool hasStructure = (place.subThoroughfare != null && place.subThoroughfare!.isNotEmpty);
        if (hasStructure) {
          _showCreationBottomSheet(coord, place);
        } else {
          HapticFeedback.vibrate();
        }
      } else {
        HapticFeedback.vibrate();
      }
    } catch (e) {
      print("Geocoding failed: $e");
      HapticFeedback.vibrate();
    }
  }

  void _showCreationBottomSheet(LatLng coord, Placemark place) {
    String address = [
      if (place.subThoroughfare?.isNotEmpty == true) place.subThoroughfare,
      if (place.thoroughfare?.isNotEmpty == true) place.thoroughfare,
      if (place.locality?.isNotEmpty == true) place.locality,
    ].whereType<String>().join(', ');

    if (address.isEmpty) address = 'Unknown Address';

    bool isSaving = false;
    bool isSaved = false;
    Post? createdPost;
    final TextEditingController _messageController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
                left: 24.0,
                right: 24.0,
                top: 24.0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Create Memory',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: TextEditingController(text: address),
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: 'Location',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      filled: true,
                      fillColor: Colors.grey[200],
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      labelText: 'Memory Details',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    maxLines: 3,
                    enabled: !isSaved && !isSaving,
                  ),
                  const SizedBox(height: 24),
                  if (!isSaved)
                    ElevatedButton(
                      onPressed: isSaving ? null : () async {
                        if (_messageController.text.isEmpty) return;
                        setModalState(() => isSaving = true);
                        try {
                          final newPost = Post(
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            messageContent: _messageController.text,
                            creatorId: 'user_123',
                            reach: 50,
                            visibilityType: '1-to-many',
                            isSafe: true,
                            altitude: 0.0,
                            placeName: address,
                          );
                          createdPost = await _apiService.createPost(newPost);
                          setModalState(() {
                            isSaved = true;
                            isSaving = false;
                          });
                          _fetchProperties(coord.latitude, coord.longitude);
                        } catch (e) {
                          setModalState(() => isSaving = false);
                          print('Failed to save post: $e');
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.blueAccent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: isSaving 
                        ? const SizedBox(
                            width: 24, 
                            height: 24, 
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                          )
                        : const Text('Save Post', style: TextStyle(fontSize: 18, color: Colors.white)),
                    ),
                  if (isSaved && createdPost != null)
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        Map<String, dynamic> propertyData = {
                          'id': createdPost!.id ?? '',
                          'lat': createdPost!.latitude,
                          'lng': createdPost!.longitude,
                          'price': createdPost!.messageContent,
                        };
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ArRevealScreen(propertyData: propertyData),
                          ),
                        );
                      },
                      icon: const Icon(Icons.view_in_ar, size: 24, color: Colors.white),
                      label: const Text('View in AR', style: TextStyle(fontSize: 18, color: Colors.white)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _setDarkMapStyle(GoogleMapController controller) {
    controller.setMapStyle('''
    [
      {"elementType":"geometry","stylers":[{"color":"#212121"}]},
      {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
      {"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},
      {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},
      {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#181818"}]},
      {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},
      {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
      {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},
      {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},
      {"featureType":"road.arterial","elementType":"geometry","stylers":[{"color":"#373737"}]},
      {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},
      {"featureType":"road.highway.controlled_access","elementType":"geometry","stylers":[{"color":"#4e4e4e"}]},
      {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
      {"featureType":"transit","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
      {"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},
      {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}
    ]
    ''');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GoogleMap(
        initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 19.0, tilt: 45.0),
        markers: _markers,
        circles: _circles,
        onTap: _handleMapTap,
        myLocationEnabled: _locationGranted,
        myLocationButtonEnabled: _locationGranted,
        zoomControlsEnabled: false,
        mapType: MapType.normal,
        onMapCreated: (controller) {
          _mapController = controller;
          _setDarkMapStyle(controller);
        },
      ),
    );
  }
}

