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

  // ─── Price-Tag Pill Marker ─────────────────────────────────────────
  Future<BitmapDescriptor> _buildPriceTagMarker(String label) async {
    const double w = 160.0;
    const double h = 60.0;
    const double r = 30.0;
    const double tipH = 12.0;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Pill path with downward triangle tip
    final pillPath = Path()
      ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 0, w, h), const Radius.circular(r)))
      ..moveTo(w / 2 - 12, h)
      ..lineTo(w / 2, h + tipH)
      ..lineTo(w / 2 + 12, h)
      ..close();

    // Heavy blurred drop shadow for lift
    canvas.drawShadow(pillPath, Colors.black, 12.0, false);

    // High-contrast stark white pill background
    final bg = Paint()..color = Colors.white;
    canvas.drawPath(pillPath, bg);

    // Zillow-tier Typography: Massive, dark, heavy weight
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xFF0D1220), // Dark charcoal/brand black
          fontSize: 24,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    
    // Perfectly centered within the pill body (ignoring the tip)
    tp.paint(canvas, Offset((w - tp.width) / 2, (h - tp.height) / 2));

    final img = await recorder.endRecording()
        .toImage(w.toInt(), (h + tipH).toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
  }

  String _formatPrice(String raw) {
    final num = double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (num == null || num == 0) return raw.isNotEmpty ? raw : 'Listing';
    if (num >= 1000000) return '\$${(num / 1000000).toStringAsFixed(1)}M';
    if (num >= 1000) return '\$${(num / 1000).round()}K';
    return '\$${num.round()}';
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

        // Price-tag marker
        final markerIcon = await _buildPriceTagMarker(_formatPrice(centerPost.messageContent));
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

  Widget _buildHeroImage(int idx) {
    final g = _heroGradients[idx % _heroGradients.length];
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: g,
            ),
          ),
        ),
        // Faint grid overlay for architectural feel
        Opacity(
          opacity: 0.15,
          child: GridPaper(
            color: _PostColors.brand,
            divisions: 1,
            subdivisions: 1,
            interval: 28,
          ),
        ),
        // Top scrim for badge legibility
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.65), Colors.transparent],
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
                Text('ACTIVE LISTING', style: TextStyle(
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
                              itemBuilder: (_, i) => _buildHeroImage(i),
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
                            // Price
                            Text(
                              _formatPrice(p.messageContent),
                              style: const TextStyle(
                                color: _PostColors.textPrimary,
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                height: 1.0,
                              ),
                            ),
                            const SizedBox(height: 10),
                            // Beds / Baths / Sqft
                            IntrinsicHeight(
                              child: Row(
                                children: [
                                  _statChip('3', 'bds'),
                                  _vDivider(),
                                  _statChip('2', 'ba'),
                                  _vDivider(),
                                  _statChip('1,425', 'sqft'),
                                ],
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
                                  'Listing by: Post Spatial Brokerage',
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
                                  Navigator.push(context, MaterialPageRoute(
                                    builder: (_) => ArRevealScreen(propertyData: propertyData),
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
                                      Text('View Property in AR',
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
                color: Colors.white,
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
                        color: const Color(0xFFDDE3EE),
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
                          color: const Color(0xFF4F8EF7).withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.add_location_alt_rounded, color: Color(0xFF4F8EF7), size: 20),
                      ),
                      const SizedBox(width: 14),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Create Listing',
                            style: TextStyle(color: Color(0xFF0D1220), fontSize: 18, fontWeight: FontWeight.w700)),
                          Text('Property confirmed',
                            style: TextStyle(color: Color(0xFF6B7A99), fontSize: 12)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Address chip
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
                  ),
                  const SizedBox(height: 14),
                  // Message / Listing details field
                  TextField(
                    controller: messageController,
                    enabled: !isSaved && !isSaving,
                    maxLines: 3,
                    style: const TextStyle(color: Color(0xFF0D1220), fontSize: 15),
                    decoration: InputDecoration(
                      hintText: 'Price, description, listing details...',
                      hintStyle: const TextStyle(color: Color(0xFF9CA8C0), fontSize: 14),
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
                            : const Text('Save Listing',
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
            myLocationButtonEnabled: _locationGranted,
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

