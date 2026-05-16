import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../models/post.dart';
import '../ui/ar_view.dart';
import 'admin_dashboard.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

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

  // ─── Social Pin & Cluster Markers ──────────────────────────────
  Future<BitmapDescriptor> _buildSocialMarker() async {
    const double size = 40.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawShadow(Path()..addOval(Rect.fromLTWH(0,0,size,size)), Colors.black, 8.0, false);
    canvas.drawCircle(const Offset(size/2, size/2), size/2, Paint()..color = _PostColors.brand);
    
    // Icon or Initial
    final tp = TextPainter(
      text: const TextSpan(text: 'P', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  Future<BitmapDescriptor> _buildClusterMarker(int count) async {
    const double size = 48.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    canvas.drawShadow(Path()..addOval(Rect.fromLTWH(0,0,size,size)), Colors.black, 12.0, false);
    canvas.drawCircle(const Offset(size/2, size/2), size/2, Paint()..color = _PostColors.accent);
    
    final tp = TextPainter(
      text: TextSpan(text: '$count', style: const TextStyle(color: Color(0xFF0D1220), fontSize: 20, fontWeight: FontWeight.w800)),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset((size - tp.width) / 2, (size - tp.height) / 2));

    final img = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  void _animateToPosition(Position pos) {
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(pos.latitude, pos.longitude),
          zoom: 19.5,
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

        BitmapDescriptor markerIcon;
        if (cluster.length > 1) {
          markerIcon = await _buildClusterMarker(cluster.length);
        } else {
          markerIcon = await _buildSocialMarker();
        }
        newMarkers.add(
          Marker(
            markerId: MarkerId(centerPost.id ?? "cluster_${centerPost.latitude}_${centerPost.longitude}"),
            position: centerLatLng,
            icon: markerIcon,
            anchor: const Offset(0.5, 1.0),
            onTap: () {
              _showPropertyBottomSheet(cluster);
            },
          ),
        );
      }

      if (mounted) {
        setState(() {
          _markers = newMarkers;
        });
      }
    } catch (e) {
      print("Failed to fetch properties: $e");
    }
  }

  // Hero gradient palettes for POC image variety
  static const _heroGradients = [
    [Color(0xFF1a2744), Color(0xFF0D2137)],
    [Color(0xFF1f2d1f), Color(0xFF091510)],
    [Color(0xFF2d1f1f), Color(0xFF100808)],
    [Color(0xFF2a1f35), Color(0xFF0d0810)],
  ];

  Widget _buildHeroImage(Post post) {
    const String mapsApiKey = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
    final streetViewUrl = 'https://maps.googleapis.com/maps/api/streetview?size=600x400&location=${post.latitude},${post.longitude}&fov=90&pitch=0&key=$mapsApiKey';

    return Stack(
      fit: StackFit.expand,
      children: [
        Builder(
          builder: (context) {
            debugPrint('STREET VIEW URL: $streetViewUrl');
            return Image.network(
              streetViewUrl,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                debugPrint('Street View Load Failed: $error');
                return Container(
                  color: const Color(0xFF1E2D5E), // Premium dark navy fallback
                  child: GridPaper(
                    color: Colors.white.withOpacity(0.1),
                    divisions: 1,
                    subdivisions: 1,
                    interval: 28,
                  ),
                );
              },
            );
          },
        ),
        // Top scrim for badge legibility against bright sky
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            height: 80,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
              ),
            ),
          ),
        ),
        // Bottom scrim for pagination/structural legibility
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
              ),
            ),
          ),
        ),
        // ACTIVE badge
        Positioned(
          top: 14, left: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF27AE60),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: Colors.white, size: 6),
                SizedBox(width: 5),
                Text('ACTIVE POST', style: TextStyle(
                  color: Colors.white, fontSize: 10,
                  fontWeight: FontWeight.w700, letterSpacing: 1.0)),
              ],
            ),
          ),
        ),
        // 3D Spatial badge
        Positioned(
          top: 14, right: 16,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _PostColors.brand.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.view_in_ar_rounded, color: Colors.white, size: 11),
                SizedBox(width: 4),
                Text('3D', style: TextStyle(
                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _statChip(String value, String label) => RichText(
    text: TextSpan(children: [
      TextSpan(text: value, style: const TextStyle(
        color: _PostColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
      TextSpan(text: ' $label', style: const TextStyle(
        color: _PostColors.textSecondary, fontSize: 13, fontWeight: FontWeight.w400)),
    ]),
  );

  Widget _vDivider() => Container(
    margin: const EdgeInsets.symmetric(horizontal: 10),
    width: 1, height: 14,
    color: _PostColors.divider,
  );

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
            final p = cluster[currentPage];
            final propertyData = {
              'id': p.id ?? '',
              'lat': p.latitude,
              'lng': p.longitude,
              'price': p.messageContent,
            };
            return FractionallySizedBox(
              heightFactor: 0.68,
              child: Container(
                decoration: const BoxDecoration(
                  color: _PostColors.surface,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Column(
                  children: [
                    // ── Drag Handle ──────────────────────
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 6),
                        width: 40, height: 4,
                        decoration: BoxDecoration(
                          color: _PostColors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),

                    // ── Hero Carousel 40% ────────────────
                    Expanded(
                      flex: 40,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                        child: Stack(
                          children: [
                            PageView.builder(
                              itemCount: cluster.length,
                              onPageChanged: (i) => setModalState(() => currentPage = i),
                              itemBuilder: (_, i) => _buildHeroImage(cluster[i]),
                            ),
                            if (cluster.length > 1)
                              Positioned(
                                bottom: 10, left: 0, right: 0,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(cluster.length, (i) =>
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 250),
                                      margin: const EdgeInsets.symmetric(horizontal: 2.5),
                                      width: currentPage == i ? 18 : 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: currentPage == i
                                            ? Colors.white
                                            : Colors.white.withValues(alpha: 0.4),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                    )
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    // ── Data Hierarchy 60% ───────────────
                    Expanded(
                      flex: 60,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Caption
                            Text(
                              p.messageContent,
                              style: const TextStyle(
                                color: _PostColors.textPrimary,
                                fontSize: 24,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                                height: 1.2,
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Address
                            Text(
                              p.messageContent.isNotEmpty ? p.messageContent
                                  : '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}',
                              style: const TextStyle(
                                color: _PostColors.textSecondary,
                                fontSize: 13, height: 1.4,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 5),
                            // Attribution
                            Row(
                              children: [
                                Container(
                                  width: 5, height: 5,
                                  decoration: const BoxDecoration(
                                    color: _PostColors.brand, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 6),
                                const Text(
                                  'Dropped by: Spatial Community',
                                  style: TextStyle(
                                    color: _PostColors.brand, fontSize: 11,
                                    fontWeight: FontWeight.w500, letterSpacing: 0.2),
                                ),
                              ],
                            ),
                            const Spacer(),
                            // ── AR CTA ───────────────────
                            Container(
                              margin: const EdgeInsets.only(bottom: 20),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [
                                  BoxShadow(
                                    color: _PostColors.brand.withValues(alpha: 0.38),
                                    blurRadius: 24,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: GestureDetector(
                                onTap: () {
                                  HapticFeedback.heavyImpact();
                                  Navigator.pop(context);
                                  Navigator.push(context, PageRouteBuilder(
                                    opaque: false,
                                    pageBuilder: (_, __, ___) => const ArView(),
                                  ));
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [Color(0xFF3A6FD8), Color(0xFF5A9EFF)],
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: const Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.view_in_ar_rounded, color: Colors.white, size: 24),
                                      SizedBox(width: 12),
                                      Text('View Post in AR',
                                        style: TextStyle(
                                          color: Colors.white, fontSize: 17,
                                          fontWeight: FontWeight.w700, letterSpacing: 0.3)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _handleMapTap(LatLng coord) async {
    final user = AuthService().currentUser;
    if (user != null && user.isAnonymous && AuthService().hasDroppedFreePost) {
      HapticFeedback.heavyImpact();
      _showLoginBottomSheet(context, isLimitReached: true);
      return;
    }

    try {
      String address = '${coord.latitude.toStringAsFixed(5)}, ${coord.longitude.toStringAsFixed(5)}';
      
      // Attempt semantic places resolution
      final placeDetails = await _apiService.getPlaceFromCoordinates(coord.latitude, coord.longitude);
      if (placeDetails != null && placeDetails['name'] != null && placeDetails['name']!.isNotEmpty) {
        address = placeDetails['name']!;
      } else {
        // Fallback to basic placemark if Places API fails
        List<Placemark> placemarks = await placemarkFromCoordinates(coord.latitude, coord.longitude);
        if (placemarks.isNotEmpty) {
          Placemark place = placemarks.first;
          String foundAddress = [
            if (place.subThoroughfare?.isNotEmpty == true) place.subThoroughfare,
            if (place.thoroughfare?.isNotEmpty == true) place.thoroughfare,
            if (place.locality?.isNotEmpty == true) place.locality,
          ].whereType<String>().join(', ');
          if (foundAddress.isNotEmpty) {
            address = foundAddress;
          }
        }
      }
      
      HapticFeedback.vibrate();
      _showCreationBottomSheet(coord, address);
    } catch (e) {
      print("Geocoding/Places failed: $e");
      HapticFeedback.vibrate();
      _showCreationBottomSheet(coord, '${coord.latitude.toStringAsFixed(5)}, ${coord.longitude.toStringAsFixed(5)}');
    }
  }

  void _showCreationBottomSheet(LatLng coord, String address) {

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
            const String mapsApiKey = String.fromEnvironment('MAPS_API_KEY', defaultValue: '');
            final streetViewUrl = 'https://maps.googleapis.com/maps/api/streetview?size=600x400&location=${coord.latitude},${coord.longitude}&fov=90&pitch=0&key=$mapsApiKey';

            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
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
                        color: const Color(0xFFDDE3EE),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Hero Image Area
                  SizedBox(
                    height: 220,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Builder(
                          builder: (context) {
                            return Image.network(
                              streetViewUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: const Color(0xFF1E2D5E), // Premium dark navy fallback
                                  child: GridPaper(
                                    color: Colors.white.withOpacity(0.1),
                                    divisions: 1,
                                    subdivisions: 1,
                                    interval: 28,
                                  ),
                                );
                              },
                            );
                          },
                        ),
                        // Top scrim
                        Positioned(
                          top: 0, left: 0, right: 0,
                          child: Container(
                            height: 80,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                        // Bottom scrim
                        Positioned(
                          bottom: 0, left: 0, right: 0,
                          child: Container(
                            height: 60,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [Colors.black.withValues(alpha: 0.75), Colors.transparent],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Content with Padding
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Header row
                        Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: const Color(0xFF4F8EF7).withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.add_location_alt_rounded, color: Color(0xFF4F8EF7), size: 20),
                            ),
                            const SizedBox(width: 14),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Drop a Post',
                                  style: TextStyle(color: Color(0xFF0D1220), fontSize: 18, fontWeight: FontWeight.w700)),
                                Text('Location acquired',
                                  style: TextStyle(color: Color(0xFF6B7A99), fontSize: 12)),
                              ],
                            ),
                          ],
                        ),
                  const SizedBox(height: 20),
                  // Address chip
                  if (address.isNotEmpty && address != 'Unknown Location')
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF4F6FB),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFDDE3EE)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.place_rounded, color: Color(0xFF4F8EF7), size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(address,
                            style: const TextStyle(color: Color(0xFF4A5568), fontSize: 13))),
                        ],
                      ),
                    )
                  else
                    const SizedBox.shrink(),
                  const SizedBox(height: 14),
                  // Message / Listing details field
                  TextField(
                    controller: messageController,
                    enabled: !isSaved && !isSaving,
                    maxLines: 3,
                    style: const TextStyle(color: Color(0xFF0D1220), fontSize: 16, fontWeight: FontWeight.w800),
                    decoration: InputDecoration(
                      hintText: 'Caption your post...',
                      hintStyle: const TextStyle(color: Color(0xFF9CA8C0), fontSize: 14, fontWeight: FontWeight.w700),
                      filled: true,
                      fillColor: const Color(0xFFF4F6FB),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDDE3EE)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDDE3EE)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF4F8EF7), width: 1.5),
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
                            creatorId: AuthService().currentUser?.uid ?? 'anonymous',
                            ownerId: AuthService().currentUser?.uid,
                            reach: 50,
                            visibilityType: '1-to-many',
                            isSafe: true,
                            altitude: 0.0,
                            placeName: address,
                          );
                          createdPost = await _apiService.createPost(newPost);
                          AuthService().hasDroppedFreePost = true; // Mark free post dropped
                          setModalState(() { isSaved = true; isSaving = false; });
                          _fetchProperties(coord.latitude, coord.longitude);
                          
                          // Wait for sheet dismissal before showing the Toast
                          Future.delayed(const Duration(milliseconds: 1500), () {
                            if (mounted && Navigator.canPop(context)) {
                              Navigator.pop(context);
                              
                              final user = AuthService().currentUser;
                              if (user != null && user.isAnonymous) {
                                _showSaveItToast();
                              }
                            }
                          });
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
                            : const Text('Drop Post',
                                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ),
                  if (isSaved && createdPost != null)
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.heavyImpact();
                        Navigator.pop(context);
                        Navigator.push(context, PageRouteBuilder(
                          opaque: false,
                          pageBuilder: (_, __, ___) => const ArView(),
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
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _showSaveItToast() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(
          bottom: 120, // Float above bottom action buttons
          left: 20,
          right: 20,
        ),
        dismissDirection: DismissDirection.down,
        backgroundColor: const Color(0xFF0D1220),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF252D3F), width: 1),
        ),
        content: const Text(
          'Your post is live! It expires in 24 hours.',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        action: SnackBarAction(
          label: 'Save It',
          textColor: const Color(0xFF4F8EF7),
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            _showLoginBottomSheet(context);
          },
        ),
      ),
    );
  }

  void _showLoginBottomSheet(BuildContext context, {bool isLimitReached = false}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: _PostColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            left: 24,
            right: 24,
            top: 14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40, height: 4,
                decoration: BoxDecoration(color: _PostColors.divider, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.lock_person_rounded, color: _PostColors.brand, size: 48),
              const SizedBox(height: 16),
              Text(
                isLimitReached ? "You've reached your free limit." : 'Claim Your Identity',
                style: const TextStyle(color: _PostColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isLimitReached ? 'Log in to drop multiple posts.' : 'Log in to manage your posts and keep them alive past 24 hours.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: _PostColors.textSecondary, fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 32),
              TextField(
                style: const TextStyle(color: _PostColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Email address',
                  hintStyle: const TextStyle(color: _PostColors.textSecondary),
                  filled: true,
                  fillColor: _PostColors.surfaceAlt,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Auth providers coming soon!')));
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _PostColors.brand,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Continue', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 16),
              StatefulBuilder(
                builder: (context, setState) {
                  Timer? pressTimer;
                  return GestureDetector(
                    onTapDown: (_) {
                      pressTimer = Timer(const Duration(seconds: 3), () async {
                        final user = AuthService().currentUser;
                        if (user != null) {
                          final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
                          if (doc.exists && doc.data()?['role'] == 'admin') {
                            Navigator.pop(context);
                            Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminDashboardScreen()));
                          }
                        }
                      });
                    },
                    onTapUp: (_) => pressTimer?.cancel(),
                    onTapCancel: () => pressTimer?.cancel(),
                    child: const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text('v1.0.0', style: TextStyle(color: _PostColors.divider, fontSize: 12)),
                    ),
                  );
                }
              ),
            ],
          ),
        );
      },
    );
  }

  // Building-safe dark map style.
  // CRITICAL: The old style used {"elementType":"geometry"} globally, which
  // flattened all 3D building meshes to #212121 — identical to road surface.
  // This version surgically styles each featureType and explicitly gives
  // landscape.man_made (buildings) a distinct elevated color so extruded
  // meshes are visually separate from ground plane at tilt: 45.0.
  static const String _kDarkMapStyle = '''
  [
    {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
    {"elementType":"labels.text.fill","stylers":[{"color":"#8896B0"}]},
    {"elementType":"labels.text.stroke","stylers":[{"color":"#0D0F14"}]},
    {"featureType":"administrative","elementType":"geometry.stroke","stylers":[{"color":"#252D3F"}]},
    {"featureType":"landscape","elementType":"geometry.fill","stylers":[{"color":"#161B25"}]},
    {"featureType":"landscape.man_made","elementType":"geometry.fill","stylers":[{"color":"#1E2A40"}]},
    {"featureType":"landscape.man_made","elementType":"geometry.stroke","stylers":[{"color":"#2A3A5C"},{"weight":"0.5"}]},
    {"featureType":"poi","elementType":"geometry.fill","stylers":[{"color":"#111827"}]},
    {"featureType":"poi.park","elementType":"geometry.fill","stylers":[{"color":"#0f1f1a"}]},
    {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#1E2433"}]},
    {"featureType":"road","elementType":"geometry.stroke","stylers":[{"color":"#252D3F"}]},
    {"featureType":"road.arterial","elementType":"geometry.fill","stylers":[{"color":"#252D3F"}]},
    {"featureType":"road.highway","elementType":"geometry.fill","stylers":[{"color":"#2C3650"}]},
    {"featureType":"road.highway","elementType":"geometry.stroke","stylers":[{"color":"#3A4A6A"}]},
    {"featureType":"transit","elementType":"geometry.fill","stylers":[{"color":"#111827"}]},
    {"featureType":"water","elementType":"geometry.fill","stylers":[{"color":"#040810"}]},
    {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#252D3F"}]}
  ]
  ''';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 19.5, tilt: 45.0),
            markers: _markers,
            onTap: _handleMapTap,
            myLocationEnabled: _locationGranted,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            buildingsEnabled: true,
            mapType: MapType.normal,
            cloudMapId: Platform.isIOS
                ? const String.fromEnvironment('IOS_MAP_ID', defaultValue: '')
                : const String.fromEnvironment('MAP_ID', defaultValue: ''),
            onMapCreated: (controller) {
              _mapController = controller;
            },
          ),
          Positioned(
            bottom: 100,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'myLocationBtn',
              backgroundColor: Colors.white,
              onPressed: () async {
                HapticFeedback.lightImpact();
                try {
                  Position pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
                  _mapController?.animateCamera(
                    CameraUpdate.newCameraPosition(
                      CameraPosition(
                        target: LatLng(pos.latitude, pos.longitude),
                        zoom: 19.5,
                        tilt: 45.0,
                      ),
                    ),
                  );
                } catch (e) {
                  debugPrint('Error fetching location: $e');
                }
              },
              child: const Icon(
                Icons.my_location,
                color: Color(0xFF0D1220), // Dark charcoal
                size: 26,
              ),
            ),
          ),
          Positioned(
            bottom: 240,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'profileBtn',
              backgroundColor: _PostColors.surfaceAlt,
              onPressed: () {
                HapticFeedback.selectionClick();
                final user = AuthService().currentUser;
                if (user == null || user.isAnonymous) {
                  _showLoginBottomSheet(context);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile view coming soon!')));
                }
              },
              child: const Icon(
                Icons.person_rounded,
                color: _PostColors.textPrimary,
                size: 26,
              ),
            ),
          ),
          Positioned(
            bottom: 170,
            right: 16,
            child: FloatingActionButton(
              heroTag: 'arToggleBtn',
              backgroundColor: _PostColors.brand,
              onPressed: () {
                HapticFeedback.heavyImpact();
                Navigator.push(context, PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const ArView(),
                ));
              },
              child: const Icon(
                Icons.view_in_ar_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
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

