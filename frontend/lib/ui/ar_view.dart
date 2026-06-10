import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api_service.dart';
import '../models/post.dart';
import 'ar_onboarding_overlay.dart';
import '../services/auth_service.dart';
import '../screens/admin_dashboard.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class ArView extends StatefulWidget {
  const ArView({super.key});

  @override
  _ArViewState createState() => _ArViewState();
}

class _ArViewState extends State<ArView> with TickerProviderStateMixin {
  late ArCoreController arCoreController;
  final ApiService _apiService = ApiService();
  List<Post> nearbyPosts = [];
  bool _arCoreInitialized = false;
  bool _postsRendered = false;
  final Set<String> _renderedPostIds = {};
  Timer? _vpsTimer;
  int _vpsScanSeconds = 0;
  Timer? _holdHapticTimer;
  Map<String, dynamic>? _currentPose;

  // Two-Phase Onboarding state
  bool _hasVpsLock = false;
  VioFailureReason _vioFailureReason = VioFailureReason.none;

  // Target property for the Phase 1 compass.
  // These are passed from the parent navigator route in a real app;
  // the fallbacks below ensure the compass always shows something meaningful.
  static const double _targetLat = 40.7128;
  static const double _targetLng = -74.0060;
  static const String _targetName = 'Target Property';

  // UI / AR Decoupling
  final GlobalKey _arCoreKey = GlobalKey();
  final ValueNotifier<int> _overlayTrigger = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    if (mounted) {
      fn();
      _overlayTrigger.value++;
    }
  }

  // Ghost-Pin state
  bool _isAuraTargetingBuilding = false;
  bool _isHolding = false;
  bool _isDialogShowing = false;
  double _holdProgress = 0.0; // 0.0 → 1.0 over the hold duration
  static const Duration _holdDuration = Duration(milliseconds: 1200);
  DateTime? _holdStartTime;

  // Black Box Debug Recorder
  bool _isRecording = false;
  int _recordingTick = 0;
  Timer? _recordingTimer;
  final StringBuffer _debugLog = StringBuffer();
  int _buildingHitCount = 0;

  // Demo Mode (iPad / unsupported device)
  bool _isDemoMode = false;
  String _demoModeReason = '';

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
          if (pose != null && pose['accuracy'] < 3.0) {
            _vpsScanSeconds = 0;
            if (!_hasVpsLock) {
              setState(() {
                _hasVpsLock = true;
                _vioFailureReason = VioFailureReason.none;
              });
            }
            if (!_postsRendered) {
              print('VPS Lock Achieved: Rendering ${nearbyPosts.length} persistent posts');
              _postsRendered = true;
              _renderPosts();
            }
          } else {
            // No lock yet — decode failure reason from native payload
            if (_hasVpsLock) {
              setState(() => _hasVpsLock = false);
            }
            final reason = pose?['trackingFailureReason'] as String?;
            final nextReason = reason == 'EXCESSIVE_MOTION'
                ? VioFailureReason.excessiveMotion
                : reason == 'INSUFFICIENT_FEATURES'
                    ? VioFailureReason.insufficientFeatures
                    : VioFailureReason.none;
            if (nextReason != _vioFailureReason) {
              setState(() => _vioFailureReason = nextReason);
            }
            _vpsScanSeconds++;
            if (_vpsScanSeconds == 15 && !_isDemoMode) {
              _showVPSFallbackDialog();
            }
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
    arCoreController.onTerrainAnchorResolved = _handleTerrainAnchorResolved;
    arCoreController.onCenterHitBuilding = _handleCenterHitBuilding;
    arCoreController.onCompatibilityError = _handleCompatibilityError;
    _arCoreInitialized = true;
    arCoreController.resume();
    // Do NOT call _renderPosts() here — Earth is not tracking yet.
    // Posts will be rendered by _updateVPS once accuracy < 3.0.
    _vpsTimer = Timer.periodic(Duration(seconds: 1), (_) => _updateVPS());
  }

  void _handleCompatibilityError(Map<String, dynamic> info) {
    if (mounted) {
      setState(() {
        _isDemoMode = info['isDemoMode'] == true;
        _demoModeReason = info['reason'] as String? ?? 'This device does not support spatial features.';
      });
    }
  }

  void _showVPSFallbackDialog() {
    if (_isDemoMode) return;
    _vpsTimer?.cancel(); // Stop hammering the VPS check while dialog is up
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF1A1A2E),
        title: Text('Spatial Features Limited', style: TextStyle(color: Colors.white)),
        content: Text(
          'Visual localization is limited in this area. You can still browse the map and view existing pins in 2D mode.',
          style: TextStyle(color: Colors.white70)
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _vpsScanSeconds = -9999; // Prevent re-triggering for this session
              // Resume timer just to keep updating accuracy if they want
              _vpsTimer = Timer.periodic(Duration(seconds: 1), (_) => _updateVPS());
            },
            child: Text('Keep Scanning', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Go back to Map
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            child: Text('Return to Map'),
          ),
        ]
      )
    );
  }

  // ─── Ghost-Pin Targeting ───────────────────────────────────────

  void _handleCenterHitBuilding(bool isBuilding) {
    if (_isAuraTargetingBuilding != isBuilding && mounted) {
      setState(() => _isAuraTargetingBuilding = isBuilding);
      if (isBuilding) {
        HapticFeedback.lightImpact();
        if (_isRecording) _buildingHitCount++;
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
    final user = AuthService().currentUser;
    if (user != null && user.isAnonymous && AuthService().hasDroppedFreePost) {
      HapticFeedback.heavyImpact();
      _showLoginBottomSheet(context, isLimitReached: true);
      return;
    }

    if (_currentPose == null) return;

    final acc = _currentPose!['accuracy'] ?? 999.0;
    if (acc > 3.0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Building lock required. Look at facades to localize (${acc.toStringAsFixed(1)}m).'),
        backgroundColor: Colors.black87,
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
    String selectedPostType = 'pin';

    // Contextual quick-message presets based on the surface type
    final List<String> quickMessages = ["Leave a note", "Hidden Gem", "Checkout this spot", "Meet me here", "Custom..."];

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
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  // Handle bar
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                  SizedBox(height: 16),

                  // Place name header
                  if (placeName.isNotEmpty && placeName != 'Unknown Location')
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
                    )
                  else
                    const SizedBox.shrink(),
                  SizedBox(height: 8),
                  Text('Surface: $placeCategory',
                    style: TextStyle(fontSize: 13, color: Colors.white38),
                  ),
                  SizedBox(height: 20),

                  // Post Reason Dropdown
                  DropdownButtonFormField<String>(
                    decoration: InputDecoration(
                      labelText: 'Post Reason',
                      labelStyle: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
                      filled: true,
                      fillColor: Colors.black.withOpacity(0.3),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.cyanAccent),
                      ),
                    ),
                    dropdownColor: Color(0xFF1A1A2E),
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                    icon: Icon(Icons.keyboard_arrow_down, color: Colors.cyanAccent),
                    items: quickMessages.map((msg) => DropdownMenuItem(
                      value: msg,
                      child: Text(msg),
                    )).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setModalState(() {
                          if (value != "Custom...") {
                            contentController.text = value;
                          }
                        });
                      }
                    },
                    hint: Text('Select Reason', style: TextStyle(color: Colors.white38, fontWeight: FontWeight.w600)),
                  ),
                  SizedBox(height: 16),

                  // Post Type Selection
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ChoiceChip(
                        label: Text('📍 Ground Pin'),
                        selected: selectedPostType == 'pin',
                        onSelected: (val) {
                          if (val) setModalState(() => selectedPostType = 'pin');
                        },
                        selectedColor: Colors.cyanAccent,
                        backgroundColor: Colors.black45,
                        labelStyle: TextStyle(color: selectedPostType == 'pin' ? Colors.black : Colors.white),
                      ),
                      SizedBox(width: 16),
                      ChoiceChip(
                        label: Text('🎈 Sky Balloon'),
                        selected: selectedPostType == 'balloon',
                        onSelected: (val) {
                          if (val) setModalState(() => selectedPostType = 'balloon');
                        },
                        selectedColor: Colors.cyanAccent,
                        backgroundColor: Colors.black45,
                        labelStyle: TextStyle(color: selectedPostType == 'balloon' ? Colors.black : Colors.white),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),

                  // Custom message input / Caption
                  TextField(
                    controller: contentController,
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
                    decoration: InputDecoration(
                      labelText: 'Caption',
                      labelStyle: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700),
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
                              final postAlt = selectedPostType == 'balloon' ? alt + 15.0 : alt;
                              final newPost = Post(
                                latitude: lat, longitude: lng, altitude: postAlt,
                                messageContent: contentController.text,
                                creatorId: AuthService().currentUser?.uid ?? 'anonymous',
                                ownerId: AuthService().currentUser?.uid,
                                visibilityType: '1-to-many',
                                reach: 50,
                                placeName: placeName,
                                placeCategory: placeCategory,
                                postType: selectedPostType,
                                expiresAt: DateTime.now().add(const Duration(hours: 24)),
                              );

                              final created = await _apiService.createPost(newPost);
                              AuthService().hasDroppedFreePost = true; // Mark free post dropped

                              if (created.isFlagged == false) {
                                // Solidify the ghost pin into a real AR sphere
                                final material = ArCoreMaterial(color: Colors.cyanAccent.withOpacity(0.9));
                                final sphere = ArCoreSphere(materials: [material], radius: 0.2);
                                final node = ArCoreNode(
                                  name: created.id ?? "pin_${DateTime.now().millisecondsSinceEpoch}",
                                  shape: sphere,
                                );

                                if (selectedPostType == 'pin') {
                                  await arCoreController.resolveAnchorOnTerrainAsync(node, lat, lng, 0.0);
                                } else {
                                  await arCoreController.addEarthAnchorNode(node, lat, lng, postAlt);
                                }

                                // THE THUD
                                HapticFeedback.heavyImpact();
                                await Future.delayed(Duration(milliseconds: 100));
                                HapticFeedback.heavyImpact();

                                setState(() {
                                  nearbyPosts.add(created);
                                  _renderedPostIds.add(node.name!);
                                });

                                Navigator.pop(sheetContext);
                                
                                // Show beautiful success dialog
                                showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (BuildContext context) {
                                    return Center(
                                      child: TweenAnimationBuilder<double>(
                                        tween: Tween<double>(begin: 0.0, end: 1.0),
                                        duration: const Duration(milliseconds: 600),
                                        curve: Curves.elasticOut,
                                        builder: (context, value, child) {
                                          return Transform.scale(
                                            scale: value,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(0.85),
                                                borderRadius: BorderRadius.circular(24),
                                                border: Border.all(color: Colors.cyanAccent.withOpacity(0.5), width: 2),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: Colors.cyanAccent.withOpacity(0.3),
                                                    blurRadius: 20,
                                                    spreadRadius: 5,
                                                  )
                                                ]
                                              ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(Icons.check_circle_outline, color: Colors.cyanAccent, size: 64),
                                                  const SizedBox(height: 16),
                                                  const Text(
                                                    'POST DROPPED',
                                                    style: TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 22,
                                                      fontWeight: FontWeight.w800,
                                                      letterSpacing: 2,
                                                      decoration: TextDecoration.none,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  Text(
                                                    'Live in AR for everyone.',
                                                    style: TextStyle(
                                                      color: Colors.white.withOpacity(0.7),
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w400,
                                                      decoration: TextDecoration.none,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    );
                                  },
                                );
                                
                                // Auto dismiss after 2 seconds
                                Future.delayed(const Duration(seconds: 2), () {
                                  if (mounted && Navigator.canPop(context)) {
                                    Navigator.pop(context);
                                    
                                    final user = AuthService().currentUser;
                                    if (user != null && user.isAnonymous) {
                                      _showSaveItToast();
                                    }
                                  }
                                });
                              } else {
                                Navigator.pop(sheetContext);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: const Text('Post submitted for moderation review.', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                    backgroundColor: Colors.orange.shade800,
                                    behavior: SnackBarBehavior.floating,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                );
                              }
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

  void _showSaveItToast() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: MediaQuery.of(context).size.height - 160,
          left: 20,
          right: 20,
        ),
        dismissDirection: DismissDirection.up,
        backgroundColor: const Color(0xFF1A1A2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: const Text(
          'Your post is live! It expires in 24 hours.',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        action: SnackBarAction(
          label: 'Save It',
          textColor: Colors.cyanAccent,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            _showLoginBottomSheet(context);
          },
        ),
      ),
    );
  }

  void _showLoginBottomSheet(BuildContext context, {bool isLimitReached = false}) {
    int tapCount = 0;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF161B25),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            left: 24, right: 24, top: 14,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: const Color(0xFF252D3F), borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 24),
              const Icon(Icons.lock_person_rounded, color: Color(0xFF4F8EF7), size: 48),
              const SizedBox(height: 16),
              Text(
                isLimitReached ? "You've reached your free limit." : 'Claim Your Identity',
                style: const TextStyle(color: Color(0xFFF0F4FF), fontSize: 24, fontWeight: FontWeight.w800),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                isLimitReached ? 'Log in to drop multiple posts.' : 'Log in to manage your posts and keep them alive past 24 hours.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF8896B0), fontSize: 14, height: 1.4),
              ),
              const SizedBox(height: 32),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton.icon(
                  onPressed: () async {
                    try {
                      await AuthService().linkWithGoogle();
                      if (context.mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Successfully linked with Google!')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Failed to link account.')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.g_mobiledata_rounded, color: Color(0xFF161B25), size: 32),
                  label: const Text('Continue with Google', style: TextStyle(color: Color(0xFF161B25), fontSize: 16, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFF0F4FF),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  tapCount++;
                  HapticFeedback.lightImpact();
                  if (tapCount >= 5) {
                    tapCount = 0;
                    final user = AuthService().currentUser;
                    if (user != null) {
                      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
                      if (doc.exists && doc.data()?['role'] == 'admin') {
                        Navigator.pop(context);
                        Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminDashboardScreen()));
                      }
                    }
                  }
                },
                child: const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('v1.0.0', style: TextStyle(color: Color(0xFF252D3F), fontSize: 12)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── Existing handlers ─────────────────────────────────────────

  void _handleTerrainAnchorResolved(String name, bool success, String? state) {
    if (success) {
      print('Terrain Anchor Lock Achieved for Post: $name');
    } else {
      print('Terrain Anchor FAILED for Post: $name | State: $state');
      // If it fails, fallback to Earth Anchor using original GPS alt
      final post = nearbyPosts.firstWhere((p) {
        String pId = p.id ?? "temp_${nearbyPosts.indexOf(p)}";
        return pId == name;
      }, orElse: () => Post(latitude: 0, longitude: 0, altitude: 0, messageContent: '', creatorId: '', visibilityType: ''));
      
      if (post.latitude != 0) {
        final material = ArCoreMaterial(color: Colors.blueAccent.withOpacity(0.8));
        final sphere = ArCoreSphere(materials: [material], radius: 0.2);
        final fallbackNode = ArCoreNode(name: name, shape: sphere);
        arCoreController.addEarthAnchorNode(fallbackNode, post.latitude, post.longitude, post.altitude);
      }
    }
  }

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
          actions: [
            IconButton(
              icon: Icon(Icons.send, color: Colors.cyanAccent),
              onPressed: () {
                String place = post.placeName != null && post.placeName != 'Unknown Location' ? post.placeName! : 'this spot';
                Share.share('Check out this Post I found at $place: ${post.messageContent}');
              },
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Close'))
          ],
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
      
      if (post.postType == 'pin') {
        arCoreController.resolveAnchorOnTerrainAsync(node, post.latitude, post.longitude, 0.0);
      } else {
        arCoreController.addEarthAnchorNode(node, post.latitude, post.longitude, post.altitude);
      }
      index++;
    }
  }

  // ─── Black Box 15-Second Debug Recorder ────────────────────────

  void _startDebugRecording() {
    if (_isRecording) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _isRecording = true;
      _recordingTick = 0;
      _buildingHitCount = 0;
    });
    _debugLog.clear();
    _debugLog.writeln('=== POST BLACK BOX — ${DateTime.now().toIso8601String()} ===');
    _debugLog.writeln('Device: Pixel 10 Pro XL | Package: com.post.spatial');
    _debugLog.writeln('');

    _recordingTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (_recordingTick >= 15) {
        _stopDebugRecording();
        return;
      }
      _appendDebugTick();
      _recordingTick++;
      if (mounted) setState(() {});
    });
  }

  void _appendDebugTick() {
    final t = _recordingTick.toString().padLeft(2, '0');
    if (_currentPose != null) {
      final acc = (_currentPose!['accuracy'] as num).toStringAsFixed(1);
      // Privacy: round GPS to 4 decimal places (~11m precision)
      final lat = (_currentPose!['latitude'] as num).toStringAsFixed(4);
      final lng = (_currentPose!['longitude'] as num).toStringAsFixed(4);
      final alt = (_currentPose!['altitude'] as num).toStringAsFixed(1);
      final hit = _isAuraTargetingBuilding ? ' | CENTER_HIT: BUILDING' : '';
      _debugLog.writeln('[${t}s] VPS: acc=${acc}m lat=$lat lng=$lng alt=$alt$hit');
    } else {
      _debugLog.writeln('[${t}s] VPS: NOT_TRACKING');
    }
  }

  void _stopDebugRecording() {
    _recordingTimer?.cancel();
    _debugLog.writeln('');
    _debugLog.writeln('[END] 15 ticks captured. $_buildingHitCount/15 BUILDING hits.');
    _debugLog.writeln('Posts loaded: ${nearbyPosts.length} | Rendered: ${_renderedPostIds.length}');
    HapticFeedback.heavyImpact();
    setState(() => _isRecording = false);
    _showDebugReviewSheet();
  }

  void _showDebugReviewSheet() {
    final logText = _debugLog.toString();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Color(0xFF1A1A2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.bug_report, color: Colors.redAccent, size: 28),
                SizedBox(width: 8),
                Text('Black Box Captured', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white)),
              ],
            ),
            SizedBox(height: 12),
            Container(
              height: 200,
              width: double.infinity,
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: SingleChildScrollView(
                child: Text(logText, style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace')),
              ),
            ),
            SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  SharePlus.instance.share(ShareParams(text: logText, subject: 'Post Bug Report'));
                },
                icon: Icon(Icons.send_rounded),
                label: Text('Send to Developer', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Dismiss', style: TextStyle(color: Colors.white38)),
              ),
            ),
            SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _vpsTimer?.cancel();
    _holdHapticTimer?.cancel();
    _recordingTimer?.cancel();
    _pulseController.dispose();
    _reticleGlowController.dispose();
    if (_arCoreInitialized) arCoreController.dispose();
    super.dispose();
  }

  // ─── BUILD ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // AR Camera Feed - Isolated at the absolute base
          ArCoreView(
            key: _arCoreKey,
            onArCoreViewCreated: onArCoreViewCreated,
            enableTapRecognizer: true,
            debug: true,
          ),
          
          // Overlay Confinement - Reactive State Listener
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: _overlayTrigger,
              builder: (context, _, _) {
                final hasVPS = _currentPose != null && (_currentPose!['accuracy'] ?? 999.0) < 3.0;

                return GestureDetector(
                  onLongPressStart: (_) => _startHold(),
                  onLongPressEnd: (_) => _releaseHold(),
                  child: Stack(
                    children: [
                      // ── PHASE 1 & 2: Two-Phase Onboarding Overlay ──
                      // Strictly inside ValueListenableBuilder. Never touches ArCoreView.
                      if (!_isDemoMode)
                        ArOnboardingOverlay(
                          targetLat: _targetLat,
                          targetLng: _targetLng,
                          propertyName: _targetName,
                          isTracking: _hasVpsLock,
                          failureReason: _vioFailureReason,
                        ),

                      // ── DEMO MODE OVERLAY (iPad / unsupported device) ──
            if (_isDemoMode)
              Container(
                color: Color(0xFF0A0E1A),
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.smartphone, color: Colors.cyanAccent, size: 64),
                        SizedBox(height: 24),
                        Text('Spatial Features Not Available',
                          style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 12),
                        Text(_demoModeReason,
                          style: TextStyle(color: Colors.cyanAccent, fontSize: 15),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 20),
                        Text('For the full augmented reality experience,\nuse Post on iPhone.',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 32),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: Icon(Icons.arrow_back, color: Colors.cyanAccent),
                          label: Text('Back to Map', style: TextStyle(color: Colors.cyanAccent)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.cyanAccent.withOpacity(0.5)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── RETICLE: Glowing cyan ring (always visible) ──
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.mediumImpact();
                  if (hasVPS) {
                    _dropGhostPin();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(40.0),
                  child: AnimatedBuilder(
                    animation: _reticleGlowAnimation,
                    builder: (context, child) {
                      final isLocked = _isAuraTargetingBuilding && hasVPS;
                      return Icon(
                        Icons.location_pin,
                        color: isLocked ? Colors.cyanAccent : Colors.white70,
                        size: isLocked ? 48 : 36,
                        shadows: isLocked ? [
                          Shadow(color: Colors.cyanAccent.withOpacity(0.5), blurRadius: 20),
                        ] : [],
                      );
                    },
                  ),
                ),
              ),
            ),

            // ── SCANNING OVERLAY INSTRUCTIONS ──
            if (!hasVPS && !_isDemoMode && _vpsScanSeconds > 2 && _vpsScanSeconds < 15)
              Positioned(
                bottom: 120,
                left: 24,
                right: 24,
                child: Container(
                  padding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.cyanAccent.withOpacity(0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.camera_alt_outlined, color: Colors.cyanAccent, size: 28),
                      SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'Scanning...\nSlowly pan your phone across building facades to localize.',
                          style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
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
                    // 🐛 Bug Report button
                    Container(
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.redAccent.withOpacity(0.3) : Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: IconButton(
                        icon: Icon(
                          Icons.bug_report_rounded,
                          color: _isRecording ? Colors.redAccent : Colors.white70,
                          size: 24,
                        ),
                        onPressed: _isRecording ? null : _startDebugRecording,
                        tooltip: 'Bug Report (15s)',
                      ),
                    ),
                    SizedBox(width: 8),
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
                          ? 'Long-press anywhere to drop a Pin'
                          : 'Scanning for VPS lock...',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                ],
                ),
              ), // end Positioned
            ], // end Stack children
          ), // end Stack
        ); // end return GestureDetector
      }, // end builder
    ), // end ValueListenableBuilder
  ), // end Positioned.fill
  ],
  ),
  );
  }
}
