import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import 'ar_view.dart';

class ProgressiveView extends StatefulWidget {
  @override
  _ProgressiveViewState createState() => _ProgressiveViewState();
}

class _ProgressiveViewState extends State<ProgressiveView> {
  final ApiService _apiService = ApiService();
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  bool _locationGranted = false;

  // Hardcoded 115 Miller Ave, Floral Park — renders in < 500ms, zero async needed.
  static const LatLng _floralPark = LatLng(40.723000, -73.705200);

  @override
  void initState() {
    super.initState();
    // Both of these are fire-and-forget — they update state when ready
    // but the map is already on screen with the hardcoded coordinates.
    _requestPermissionsAndRefine();
    _fetchGhostNodes(_floralPark.latitude, _floralPark.longitude);
  }

  /// Request location permission, then refine the map center.
  Future<void> _requestPermissionsAndRefine() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.always || permission == LocationPermission.whileInUse) {
        if (mounted) setState(() => _locationGranted = true);
        _refineLocation();
      }
    } catch (e) {
      print("Permission request failed (non-fatal): $e");
    }
  }

  /// Two-pass location: instant cached snap → precise GPS lock.
  Future<void> _refineLocation() async {
    try {
      // Pass 1: Instant snap from cache (may be stale but gets the camera close)
      Position? cached = await Geolocator.getLastKnownPosition(forceAndroidLocationManager: true);
      if (cached != null && mounted) {
        _animateToPosition(cached);
      }

      // Pass 2: Precise high-accuracy GPS fix (the real lock)
      Position precise = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (mounted) {
        _animateToPosition(precise);
        _fetchGhostNodes(precise.latitude, precise.longitude);
      }
    } catch (e) {
      print("Location refine failed (non-fatal): $e");
    }
  }

  void _animateToPosition(Position pos) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(pos.latitude, pos.longitude),
          zoom: 18.0,
          tilt: 45.0,
        ),
      ),
    );
  }

  /// Fetch nearby posts from Firestore and render them as cyan map markers.
  Future<void> _fetchGhostNodes(double lat, double lng) async {
    try {
      final posts = await _apiService.getNearbyPosts(lat, lng);
      Set<Marker> newMarkers = {};
      int i = 0;
      for (var p in posts) {
        newMarkers.add(
          Marker(
            markerId: MarkerId(p.id ?? "post_$i"),
            position: LatLng(p.latitude, p.longitude),
            infoWindow: InfoWindow(
              title: p.placeName ?? "AR Post",
              snippet: p.messageContent,
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueCyan),
          ),
        );
        i++;
      }
      if (mounted) {
        setState(() => _markers = newMarkers);
      }
    } catch (e) {
      print("Ghost nodes fetch failed (non-fatal): $e");
    }
  }

  void _openArView() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ArView()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: _floralPark,
          zoom: 18.0,
          tilt: 45.0,
          bearing: 0.0,
        ),
        markers: _markers,
        mapType: MapType.normal,
        myLocationEnabled: _locationGranted,
        myLocationButtonEnabled: _locationGranted,
        compassEnabled: false,
        zoomControlsEnabled: false,
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 16),
        onMapCreated: (controller) {
          _mapController = controller;
          _setDarkMapStyle(controller);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openArView,
        label: Text('Enter AR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        icon: Icon(Icons.camera_alt_rounded, size: 28),
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        elevation: 8,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
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
}
