import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../models/post.dart';
import 'ar_reveal_screen.dart';

// ─── Brand Design Tokens ────────────────────────────────────────────────────
class _PostColors {
  static const bg         = Color(0xFF0D0F14);
  static const surface    = Color(0xFF161B25);
  static const surfaceAlt = Color(0xFF1E2433);
  static const brand      = Color(0xFF4F8EF7);
  static const brandDim   = Color(0xFF2A4E8C);
  static const accent     = Color(0xFFE8A838);
  static const textPrimary   = Color(0xFFF0F4FF);
  static const textSecondary = Color(0xFF8896B0);
  static const divider    = Color(0xFF252D3F);
}

// ─── Radar Arc Painter ───────────────────────────────────────────────────────
class _RadarPainter extends CustomPainter {
  final double sweep;
  _RadarPainter(this.sweep);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r  = size.width / 2;

    // Outer ring
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..color = _PostColors.brand.withValues(alpha: 0.12)
               ..style = PaintingStyle.stroke
               ..strokeWidth = 1.0);
    // Inner ring
    canvas.drawCircle(Offset(cx, cy), r * 0.6,
        Paint()..color = _PostColors.brand.withValues(alpha: 0.08)
               ..style = PaintingStyle.stroke
               ..strokeWidth = 1.0);
    // Centre dot
    canvas.drawCircle(Offset(cx, cy), 3,
        Paint()..color = _PostColors.brand.withValues(alpha: 0.6));

    // Sweep arc gradient
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: sweep - 0.001,
        endAngle:   sweep + math.pi * 0.75,
        colors: [
          _PostColors.brand.withValues(alpha: 0.0),
          _PostColors.brand.withValues(alpha: 0.35),
        ],
        transform: GradientRotation(sweep),
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), r, sweepPaint);

    // Sweep leading line
    canvas.drawLine(
      Offset(cx, cy),
      Offset(cx + r * math.cos(sweep), cy + r * math.sin(sweep)),
      Paint()..color = _PostColors.brand.withValues(alpha: 0.7)
             ..strokeWidth = 1.5
             ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.sweep != sweep;
}

class MapScreen extends StatefulWidget {
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  GoogleMapController? _mapController;
  final LatLng _initialPosition = const LatLng(40.7251, -73.7055);
  Set<Marker> _markers = {};
  Set<Circle> _circles = {};
  bool _locationGranted = false;

  bool _isBooting = true;
  Timer? _bootTimer;
  int _bootTextIndex = 0;
  final List<String> _bootTexts = [
    "Initializing spatial grid...",
    "Acquiring satellite lock...",
    "Resolving architectural entities..."
  ];
  String _currentBootText = "Initializing spatial grid...";

  late final AnimationController _radarCtrl;
  late final AnimationController _bootTextCtrl;
  late final Animation<double> _bootTextOpacity;

  @override
  void initState() {
    super.initState();

    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _bootTextCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
      value: 1.0,
    );
    _bootTextOpacity = CurvedAnimation(parent: _bootTextCtrl, curve: Curves.easeInOut);

    _bootTimer = Timer.periodic(const Duration(milliseconds: 1600), (timer) {
      if (!mounted) return;
      _bootTextCtrl.reverse().then((_) {
        if (mounted) {
          setState(() {
            _bootTextIndex = (_bootTextIndex + 1) % _bootTexts.length;
            _currentBootText = _bootTexts[_bootTextIndex];
          });
          _bootTextCtrl.forward();
        }
      });
    });
    _requestPermissionsAndCenter();
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
    _radarCtrl.dispose();
    _bootTextCtrl.dispose();
    super.dispose();
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
        
        if (mounted) {
          setState(() {
            _isBooting = false;
            _bootTimer?.cancel();
          });
        }
      } else {
        // Fallback fetch if permission denied
        _fetchProperties(_initialPosition.latitude, _initialPosition.longitude);
        if (mounted) {
          setState(() {
            _isBooting = false;
            _bootTimer?.cancel();
          });
        }
      }
    } catch (e) {
      print("Location permission or fetch failed: $e");
      _fetchProperties(_initialPosition.latitude, _initialPosition.longitude);
      if (mounted) {
        setState(() {
          _isBooting = false;
          _bootTimer?.cancel();
        });
      }
    }
  }

  void _animateToPosition(Position pos) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(pos.latitude, pos.longitude),
          zoom: 19.0,
          tilt: 45.0,
          bearing: pos.heading >= 0.0 ? pos.heading : 0.0,
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
            fillColor: const Color(0x224F8EF7),
            strokeColor: const Color(0xFF4F8EF7),
            strokeWidth: 2,
          ),
        );
        // Outer halo
        newCircles.add(
          Circle(
            circleId: CircleId('halo_${centerPost.id ?? "${centerPost.latitude}_${centerPost.longitude}"}'),
            center: centerLatLng,
            radius: 24.0,
            fillColor: const Color(0x0A4F8EF7),
            strokeColor: const Color(0x554F8EF7),
            strokeWidth: 1,
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
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        int currentPage = 0;
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: _PostColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 14),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _PostColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Cluster badge
                  if (cluster.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _PostColors.brand.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _PostColors.brand.withValues(alpha: 0.4), width: 1),
                        ),
                        child: Text(
                          '${cluster.length} properties at this location',
                          style: const TextStyle(color: _PostColors.brand, fontSize: 11, fontWeight: FontWeight.w500, letterSpacing: 0.5),
                        ),
                      ),
                    ),
                  // PageView cards
                  SizedBox(
                    height: 200,
                    child: PageView.builder(
                      itemCount: cluster.length,
                      onPageChanged: (i) => setModalState(() => currentPage = i),
                      itemBuilder: (context, index) {
                        final p = cluster[index];
                        final propertyData = {
                          'id': p.id ?? '',
                          'lat': p.latitude,
                          'lng': p.longitude,
                          'price': p.messageContent,
                        };
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Address row
                            Row(
                              children: [
                                Container(
                                  width: 36, height: 36,
                                  decoration: BoxDecoration(
                                    color: _PostColors.brand.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(Icons.location_on_rounded, color: _PostColors.brand, size: 18),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    p.messageContent,
                                    style: const TextStyle(
                                      color: _PostColors.textPrimary,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      height: 1.2,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            // AR Button — premium glow
                            GestureDetector(
                              onTap: () {
                                HapticFeedback.heavyImpact();
                                Navigator.pop(context);
                                Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => ArRevealScreen(propertyData: propertyData),
                                ));
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 17),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF3A6FD8), Color(0xFF4F8EF7)],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _PostColors.brand.withValues(alpha: 0.35),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: const Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.view_in_ar_rounded, color: Colors.white, size: 22),
                                    SizedBox(width: 10),
                                    Text('View in AR',
                                      style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  // Page dots
                  if (cluster.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(cluster.length, (i) => AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: currentPage == i ? 20 : 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: currentPage == i ? _PostColors.brand : _PostColors.divider,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        )),
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
    final messageController = TextEditingController();

    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: _PostColors.surface,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                left: 24, right: 24, top: 0,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 14),
                      width: 40, height: 4,
                      decoration: BoxDecoration(
                        color: _PostColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Header row
                  Row(
                    children: [
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          color: _PostColors.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.add_location_alt_rounded, color: _PostColors.accent, size: 20),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Drop a Memory', style: TextStyle(color: _PostColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
                          Text('Structure confirmed', style: TextStyle(color: _PostColors.textSecondary, fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Address chip
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: _PostColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _PostColors.divider),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.place_rounded, color: _PostColors.brand, size: 16),
                        const SizedBox(width: 8),
                        Expanded(child: Text(address, style: const TextStyle(color: _PostColors.textSecondary, fontSize: 13))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // Message field
                  TextField(
                    controller: messageController,
                    enabled: !isSaved && !isSaving,
                    maxLines: 3,
                    style: const TextStyle(color: _PostColors.textPrimary, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'What do you want to remember here?',
                      hintStyle: const TextStyle(color: _PostColors.textSecondary, fontSize: 14),
                      filled: true,
                      fillColor: _PostColors.surfaceAlt,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _PostColors.divider),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _PostColors.divider),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _PostColors.brand, width: 1.5),
                      ),
                      contentPadding: const EdgeInsets.all(14),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (!isSaved)
                    GestureDetector(
                      onTap: isSaving ? null : () async {
                        if (messageController.text.isEmpty) return;
                        setModalState(() => isSaving = true);
                        try {
                          final newPost = Post(
                            latitude: coord.latitude,
                            longitude: coord.longitude,
                            messageContent: messageController.text,
                            creatorId: 'user_123',
                            reach: 50,
                            visibilityType: '1-to-many',
                            isSafe: true,
                            altitude: 0.0,
                            placeName: address,
                          );
                          createdPost = await _apiService.createPost(newPost);
                          setModalState(() { isSaved = true; isSaving = false; });
                          _fetchProperties(coord.latitude, coord.longitude);
                        } catch (e) {
                          setModalState(() => isSaving = false);
                        }
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        padding: const EdgeInsets.symmetric(vertical: 17),
                        decoration: BoxDecoration(
                          gradient: isSaving
                            ? const LinearGradient(colors: [Color(0xFF2A3A5C), Color(0xFF2A3A5C)])
                            : const LinearGradient(colors: [Color(0xFF3A6FD8), Color(0xFF4F8EF7)]),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: isSaving ? [] : [
                            BoxShadow(
                              color: _PostColors.brand.withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Center(
                          child: isSaving
                            ? const SizedBox(width: 22, height: 22,
                                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                            : const Text('Save Memory',
                                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  if (isSaved && createdPost != null)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.heavyImpact();
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(
                          builder: (_) => ArRevealScreen(propertyData: {
                            'id': createdPost!.id ?? '',
                            'lat': createdPost!.latitude,
                            'lng': createdPost!.longitude,
                            'price': createdPost!.messageContent,
                          }),
                        ));
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 17),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFF1E7C4A), Color(0xFF27AE60)],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF27AE60).withValues(alpha: 0.3),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.view_in_ar_rounded, color: Colors.white, size: 22),
                            SizedBox(width: 10),
                            Text('Reveal in AR',
                              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                          ],
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
      body: Stack(
        children: [
          GoogleMap(
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
          IgnorePointer(
            ignoring: !_isBooting,
            child: AnimatedOpacity(
              opacity: _isBooting ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOut,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF0A0D14), Color(0xFF0D1220)],
                  ),
                ),
                child: SafeArea(
                  child: Column(
                    children: [
                      const Spacer(flex: 2),
                      // Wordmark
                      const Text(
                        'POST',
                        style: TextStyle(
                          color: _PostColors.textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 10,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'SPATIAL',
                        style: TextStyle(
                          color: _PostColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 6,
                        ),
                      ),
                      const Spacer(),
                      // Radar
                      AnimatedBuilder(
                        animation: _radarCtrl,
                        builder: (_, __) => SizedBox(
                          width: 140,
                          height: 140,
                          child: CustomPaint(
                            painter: _RadarPainter(_radarCtrl.value * 2 * math.pi),
                          ),
                        ),
                      ),
                      const Spacer(),
                      // Animated micro-copy
                      FadeTransition(
                        opacity: _bootTextOpacity,
                        child: Text(
                          _currentBootText,
                          style: const TextStyle(
                            color: _PostColors.textSecondary,
                            fontSize: 13,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Slim progress bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 64),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: AnimatedBuilder(
                            animation: _radarCtrl,
                            builder: (_, __) => LinearProgressIndicator(
                              value: null,
                              minHeight: 2,
                              backgroundColor: _PostColors.divider,
                              valueColor: AlwaysStoppedAnimation(_PostColors.brand),
                            ),
                          ),
                        ),
                      ),
                      const Spacer(flex: 2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

