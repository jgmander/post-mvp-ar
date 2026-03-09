import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'package:geolocator/geolocator.dart';
import '../services/api_service.dart';
import '../models/post.dart';

class ArView extends StatefulWidget {
  const ArView({Key? key}) : super(key: key);

  @override
  _ArViewState createState() => _ArViewState();
}

class _ArViewState extends State<ArView> with TickerProviderStateMixin {
  late ArCoreController arCoreController;
  final ApiService _apiService = ApiService();
  List<Post> nearbyPosts = [];
  bool _arCoreInitialized = false;
  bool _postsRendered = false;
  Set<String> _renderedPostIds = {};
  Timer? _vpsTimer;
  Timer? _holdHapticTimer;
  Map<String, dynamic>? _currentPose;

  // Ghost-Pin state
  bool _isAuraTargetingBuilding = false;
  bool _isHolding = false;
  bool _isDialogShowing = false;
  double _holdProgress = 0.0; // 0.0 → 1.0 over the hold duration
  static const Duration _holdDuration = Duration(milliseconds: 1200);
  DateTime? _holdStartTime;

  // Pulse animation for the ghost sphere
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Reticle glow animation
  late AnimationController _reticleGlowController;
  late Animation<double> _reticleGlowAnimation;

  @override
  void initState() {
    super.initState();

    // Pulse animation: 1.0 → 1.4 → 1.0 (breathing ghost sphere)
    _pulseController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.4).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Reticle glow: subtle ambient pulse
    _reticleGlowController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _reticleGlowAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _reticleGlowController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPostsInBackground();
    });
  }

  Future<void> _loadPostsInBackground() async {
    try {
      Position? position = await Geolocator.getLastKnownPosition();
      position ??= Position(
        latitude: 40.723000, longitude: -73.705200,
        timestamp: DateTime.now(), accuracy: 100, altitude: 0,
        heading: 0, speed: 0, speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0,
      );
      final posts = await _apiService.getNearbyPosts(position.latitude, position.longitude);
      if (mounted) {
        setState(() => nearbyPosts = posts);
        _renderPosts();
      }
    } catch (e) {
      print("AR background post load failed (non-fatal): $e");
    }
  }

  Future<void> _updateVPS() async {
    if (_arCoreInitialized) {
      try {
        final pose = await arCoreController.getGeospatialPose();
        if (mounted) {
          setState(() => _currentPose = pose);
          if (pose != null && pose['accuracy'] < 3.0 && !_postsRendered) {
            print('VPS Lock Achieved: Rendering ${nearbyPosts.length} persistent posts');
            _postsRendered = true;
            _renderPosts();
          }
        }
      } catch (_) {}
    }
  }

  void onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;
    arCoreController.onNodeTap = (name) => _handleOnNodeTap(name);
    arCoreController.onPlaneTap = _handleOnPlaneTap;
    arCoreController.onRooftopAnchorResolved = _handleRooftopAnchorResolved;
    arCoreController.onCenterHitBuilding = _handleCenterHitBuilding;
    _arCoreInitialized = true;
    arCoreController.resume();
    // Do NOT call _renderPosts() here — Earth is not tracking yet.
    // Posts will be rendered by _updateVPS once accuracy < 3.0.
    _vpsTimer = Timer.periodic(Duration(seconds: 1), (_) => _updateVPS());
  }

  // ─── Ghost-Pin Targeting ───────────────────────────────────────

  void _handleCenterHitBuilding(bool isBuilding) {
    if (_isAuraTargetingBuilding != isBuilding && mounted) {
      setState(() => _isAuraTargetingBuilding = isBuilding);
      if (isBuilding) {
        HapticFeedback.lightImpact();
      }
    }
  }

  // ─── Long-Press "Point, Hold, Release" ─────────────────────────

  void _startHold() {
    if (!_isAuraTargetingBuilding) return; // Only allow when targeting a building

    setState(() {
      _isHolding = true;
      _holdProgress = 0.0;
      _holdStartTime = DateTime.now();
    });

    // Escalating haptics: selection clicks during hold
    _holdHapticTimer = Timer.periodic(Duration(milliseconds: 150), (timer) {
      if (!_isHolding) {
        timer.cancel();
        return;
      }
      HapticFeedback.selectionClick();
      _updateHoldProgress();
    });
  }

  void _updateHoldProgress() {
    if (_holdStartTime == null || !mounted) return;
    final elapsed = DateTime.now().difference(_holdStartTime!);
    final progress = (elapsed.inMilliseconds / _holdDuration.inMilliseconds).clamp(0.0, 1.0);
    setState(() => _holdProgress = progress);
  }

  void _releaseHold() {
    _holdHapticTimer?.cancel();

    if (!_isHolding || _holdProgress < 0.8) {
      // Cancelled or not held long enough
      setState(() {
        _isHolding = false;
        _holdProgress = 0.0;
      });
      return;
    }

    // ── THE DROP ──
    HapticFeedback.heavyImpact();
    setState(() {
      _isHolding = false;
      _holdProgress = 0.0;
    });

    // Trigger the pin creation flow using the center-screen hit
    _dropGhostPin();
  }

  Future<void> _dropGhostPin() async {
    if (_currentPose == null) return;

    final acc = _currentPose!['accuracy'] ?? 999.0;
    if (acc > 3.0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('VPS Signal too weak (${acc.toStringAsFixed(1)}m). Look at buildings to localize.'),
        backgroundColor: Colors.redAccent,
      ));
      return;
    }

    final lat = _currentPose!['latitude'] as double;
    final lng = _currentPose!['longitude'] as double;

    // Resolve the place name for the building we're looking at
    String placeName = "Unknown Location";
    String placeCategory = "BUILDING";

    try {
      final placeData = await _apiService.getPlaceFromCoordinates(lat, lng);
      if (placeData != null) {
        placeName = placeData['name'] ?? placeName;
        placeCategory = placeData['category'] ?? placeCategory;
      }
    } catch (_) {}

    _showGhostPinSheet(lat, lng, placeName, placeCategory);
  }

  // ─── The "Quick Message" Semantic CTA Sheet ────────────────────

  void _showGhostPinSheet(double lat, double lng, String placeName, String placeCategory) {
    final contentController = TextEditingController();
    bool isSubmitting = false;

    // Contextual quick-message presets based on the surface type
    final List<String> quickMessages = _getQuickMessages(placeCategory);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext sheetContext, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                left: 24, right: 24, top: 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle bar
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                  SizedBox(height: 16),

                  // Place name header
                  Row(
                    children: [
                      Icon(Icons.location_pin, color: Colors.cyanAccent, size: 28),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(placeName,
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text('Surface: $placeCategory',
                    style: TextStyle(fontSize: 13, color: Colors.white38),
                  ),
                  SizedBox(height: 20),

                  // Quick message buttons
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: quickMessages.map((msg) => ActionChip(
                      label: Text(msg, style: TextStyle(color: Colors.cyanAccent, fontSize: 14, fontWeight: FontWeight.w600)),
                      backgroundColor: Colors.cyanAccent.withOpacity(0.12),
                      side: BorderSide(color: Colors.cyanAccent.withOpacity(0.7), width: 1.5),
                      padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      onPressed: () {
                        contentController.text = msg;
                        setModalState(() {});
                      },
                    )).toList(),
                  ),
                  SizedBox(height: 16),

                  // Custom message input
                  TextField(
                    controller: contentController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Your Message',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.cyanAccent),
                      ),
                    ),
                    maxLines: 2,
                  ),
                  SizedBox(height: 20),

                  // Drop Pin button
                  isSubmitting
                    ? CircularProgressIndicator(color: Colors.cyanAccent)
                    : SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: ElevatedButton(
                          onPressed: () async {
                            if (contentController.text.isEmpty) return;
                            setModalState(() => isSubmitting = true);

                            try {
                              final alt = _currentPose!['altitude'] as double;
                              final newPost = Post(
                                latitude: lat, longitude: lng, altitude: alt,
                                messageContent: contentController.text,
                                creatorId: 'user_123',
                                visibilityType: '1-to-many',
                                reach: 50,
                                placeName: placeName,
                                placeCategory: placeCategory,
                              );

                              final created = await _apiService.createPost(newPost);

                              // Solidify the ghost pin into a real AR sphere
                              final material = ArCoreMaterial(color: Colors.cyanAccent.withOpacity(0.9));
                              final sphere = ArCoreSphere(materials: [material], radius: 0.2);
                              final node = ArCoreNode(
                                name: created.id ?? "pin_${DateTime.now().millisecondsSinceEpoch}",
                                shape: sphere,
                              );

                              await arCoreController.resolveAnchorOnRooftopAsync(node, lat, lng, 0.5);

                              // THE THUD
                              HapticFeedback.heavyImpact();
                              await Future.delayed(Duration(milliseconds: 100));
                              HapticFeedback.heavyImpact();

                              setState(() {
                                nearbyPosts.add(created);
                                _renderedPostIds.add(node.name!);
                              });

                              Navigator.pop(sheetContext);
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text('📌 Pinned! CTA: ${created.ctaText ?? 'None'}'),
                                backgroundColor: Colors.cyanAccent.withOpacity(0.8),
                              ));
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                              setModalState(() => isSubmitting = false);
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.cyanAccent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            elevation: 6,
                          ),
                          child: Text('📌 Drop Pin', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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

  List<String> _getQuickMessages(String placeCategory) {
    final cat = placeCategory.toLowerCase();
    if (cat.contains('restaurant') || cat.contains('food') || cat.contains('cafe')) {
      return ['Make Reservation', 'Great food here!', 'Try the special'];
    } else if (cat.contains('store') || cat.contains('shop')) {
      return ['Sale happening!', 'Recommend this place', 'Open until late'];
    } else if (cat.contains('residence') || cat.contains('house') || cat.contains('address') || cat.contains('building')) {
      return ['Leave Note for Resident', 'Package Delivery Alert', 'Private Post'];
    } else if (cat.contains('park') || cat.contains('recreation')) {
      return ['Beautiful spot!', 'Event here today', 'Dog friendly'];
    }
    return ['Check this out!', 'Been here before?', 'Recommend!'];
  }

  // ─── Existing handlers ─────────────────────────────────────────

  void _handleRooftopAnchorResolved(String name, bool success, String? state) {
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('✨ Precision Rooftop Anchor Locked!')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Rooftop Anchor failed: $state')));
    }
  }

  void _handleOnNodeTap(String name) {
    if (_isDialogShowing) return; // Prevent stacked dialogs from multi-node taps
    try {
      final post = nearbyPosts.firstWhere((p) {
        int index = nearbyPosts.indexOf(p);
        return (p.id ?? "temp_$index") == name;
      });
      _isDialogShowing = true;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
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
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action: ${post.ctaText}')));
                  },
                  style: ElevatedButton.styleFrom(minimumSize: Size.fromHeight(40)),
                  child: Text(post.ctaText!),
                ),
              ],
            ],
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Close'))],
        ),
      ).then((_) => _isDialogShowing = false);
    } catch (_) {}
  }

  void _handleOnPlaneTap(List<ArCoreHitTestResult> hits) async {
    // Tap-based creation is now replaced by the Ghost-Pin long-press.
    // Keep as a no-op or for future use.
  }

  void _renderPosts() {
    if (!_arCoreInitialized) return;
    int index = 0;
    for (var post in nearbyPosts) {
      String postId = post.id ?? "temp_$index";
      if (_renderedPostIds.contains(postId)) { index++; continue; }
      _renderedPostIds.add(postId);
      final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
      final sphere = ArCoreSphere(materials: [material], radius: 0.2);
      final node = ArCoreNode(name: postId, shape: sphere);
      arCoreController.addEarthAnchorNode(node, post.latitude, post.longitude, post.altitude ?? 0.0);
      index++;
    }
  }

  @override
  void dispose() {
    _vpsTimer?.cancel();
    _holdHapticTimer?.cancel();
    _pulseController.dispose();
    _reticleGlowController.dispose();
    if (_arCoreInitialized) arCoreController.dispose();
    super.dispose();
  }

  // ─── BUILD ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final hasVPS = _currentPose != null && (_currentPose!['accuracy'] ?? 999.0) < 3.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onLongPressStart: (_) => _startHold(),
        onLongPressEnd: (_) => _releaseHold(),
        child: Stack(
          children: [
            // AR Camera Feed
            ArCoreView(
              onArCoreViewCreated: onArCoreViewCreated,
              enableTapRecognizer: true,
              debug: true,
            ),

            // ── RETICLE: Glowing cyan ring (always visible) ──
            Center(
              child: AnimatedBuilder(
                animation: _reticleGlowAnimation,
                builder: (context, child) {
                  final isLocked = _isAuraTargetingBuilding && hasVPS;
                  return Container(
                    width: isLocked ? 90 : 70,
                    height: isLocked ? 90 : 70,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isLocked
                          ? Colors.cyanAccent.withOpacity(0.9)
                          : Colors.white.withOpacity(_reticleGlowAnimation.value),
                        width: isLocked ? 3 : 1.5,
                      ),
                      boxShadow: isLocked ? [
                        BoxShadow(color: Colors.cyanAccent.withOpacity(0.5), blurRadius: 25, spreadRadius: 8),
                      ] : [],
                    ),
                    child: isLocked
                      ? Center(child: Icon(Icons.add_circle_outline, color: Colors.cyanAccent, size: 32))
                      : null,
                  );
                },
              ),
            ),

            // ── GHOST SPHERE: Pulsing indicator when holding ──
            if (_isHolding && _isAuraTargetingBuilding)
              Center(
                child: AnimatedBuilder(
                  animation: _pulseAnimation,
                  builder: (context, child) {
                    final scale = _pulseAnimation.value;
                    final size = 60.0 * scale * (0.5 + _holdProgress * 0.5);
                    return Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.cyanAccent.withOpacity(0.2 + _holdProgress * 0.3),
                        border: Border.all(color: Colors.cyanAccent, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.cyanAccent.withOpacity(0.3 + _holdProgress * 0.4),
                            blurRadius: 20 + _holdProgress * 30,
                            spreadRadius: 5 + _holdProgress * 15,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),

            // ── HOLD PROGRESS ARC ──
            if (_isHolding)
              Center(
                child: SizedBox(
                  width: 100,
                  height: 100,
                  child: CircularProgressIndicator(
                    value: _holdProgress,
                    strokeWidth: 3,
                    color: Colors.cyanAccent,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),

            // ── Aura border when targeting building ──
            if (_isAuraTargetingBuilding && hasVPS && !_isHolding)
              IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.25), width: 3),
                  ),
                ),
              ),

            // ── Top bar: Back button + VPS status ──
            SafeArea(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    // Back to Map button
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.map_outlined, color: Colors.white, size: 28),
                        onPressed: () => Navigator.pop(context),
                        tooltip: 'Back to Map',
                      ),
                    ),
                    Spacer(),
                    // VPS accuracy badge
                    if (_currentPose != null)
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: hasVPS ? Colors.cyanAccent.withOpacity(0.15) : Colors.redAccent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: hasVPS ? Colors.cyanAccent.withOpacity(0.4) : Colors.redAccent.withOpacity(0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              hasVPS ? Icons.gps_fixed : Icons.gps_not_fixed,
                              color: hasVPS ? Colors.cyanAccent : Colors.redAccent,
                              size: 16,
                            ),
                            SizedBox(width: 6),
                            Text(
                              '${(_currentPose!['accuracy'] as num).toStringAsFixed(1)}m',
                              style: TextStyle(
                                color: hasVPS ? Colors.cyanAccent : Colors.redAccent,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ── Bottom: Pin Here FAB + instruction hint ──
            Positioned(
              bottom: 30,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Instruction hint
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      _isHolding
                        ? 'Hold to charge... ${(_holdProgress * 100).toInt()}%'
                        : hasVPS
                          ? 'Tap the button or long-press to pin'
                          : 'Scanning for VPS lock...',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                  SizedBox(height: 12),
                  // Big Pin FAB
                  if (hasVPS)
                    FloatingActionButton.extended(
                      onPressed: () {
                        HapticFeedback.heavyImpact();
                        _dropGhostPin();
                      },
                      label: Text('Pin Here', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      icon: Icon(Icons.push_pin_rounded, size: 24),
                      backgroundColor: Colors.cyanAccent,
                      foregroundColor: Colors.black,
                      elevation: 8,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// AnimatedBuilder is a simple alias for AnimatedWidget builder pattern
class AnimatedBuilder extends AnimatedWidget {
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;

  const AnimatedBuilder({
    Key? key,
    required Animation<double> animation,
    required this.builder,
    this.child,
  }) : super(key: key, listenable: animation);

  @override
  Widget build(BuildContext context) => builder(context, child);
}
