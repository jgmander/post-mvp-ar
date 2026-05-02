import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
          zoom: 18.5,
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
      
      for (var p in posts) {
        Map<String, dynamic> propertyData = {
          'id': p.id ?? '',
          'lat': p.latitude,
          'lng': p.longitude,
          'price': p.messageContent,
        };

        newMarkers.add(
          Marker(
            markerId: MarkerId(p.id ?? "post_${p.latitude}_${p.longitude}"),
            position: LatLng(p.latitude, p.longitude),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
            onTap: () {
              _showPropertyBottomSheet(propertyData);
            },
          ),
        );

        newCircles.add(
          Circle(
            circleId: CircleId(p.id ?? "circle_${p.latitude}_${p.longitude}"),
            center: LatLng(p.latitude, p.longitude),
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

  void _showPropertyBottomSheet(Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                data['price'] ?? 'Unknown Price',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context); // Close bottom sheet
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ArRevealScreen(propertyData: data),
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
          ),
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
        initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 18.5, tilt: 45.0),
        markers: _markers,
        circles: _circles,
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

