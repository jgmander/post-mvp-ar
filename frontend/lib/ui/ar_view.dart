import 'dart:async';
import 'dart:io';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/post.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/moderation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/login_bottom_sheet.dart';
import 'ar_onboarding_overlay.dart';

class ArView extends StatefulWidget {
  final double? initialTargetLat;
  final double? initialTargetLng;
  final String? initialTargetName;

  const ArView({
    super.key,
    this.initialTargetLat,
    this.initialTargetLng,
    this.initialTargetName,
  });

  @override
  State<ArView> createState() => _ArViewState();
}

class _ArViewState extends State<ArView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late ArCoreController arCoreController;
  final ApiService _apiService = ApiService();
  List<Post> nearbyPosts = [];
  Set<String> _hiddenPostIds = {};
  bool _arCoreInitialized = false;
  bool _postsRendered = false;
  final Set<String> _renderedPostIds = {};
  Timer? _vpsTimer;
  int _vpsScanSeconds = 0;
  Timer? _holdHapticTimer;
  Map<String, dynamic>? _currentPose;

  // Live center-crosshair raycast target from native Streetscape + Plane raycast
  Map<String, dynamic>? _centerTarget;

  // Firestore real-time listener for nearby posts (5-char geohash ~4.9km cell)
  StreamSubscription<QuerySnapshot>? _postsSubscription;
  String _currentGeohashPrefix = '';

  // Two-Phase Onboarding & Wayfinder state
  bool _hasVpsLock = false;
  VioFailureReason _vioFailureReason = VioFailureReason.none;
  double? _targetLat;
  double? _targetLng;
  String _targetName = '';
  bool _isNavigating = false;

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
  double _holdProgress = 0.0;
  static const Duration _holdDuration = Duration(milliseconds: 950);
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

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _reticleGlowController;
  late Animation<double> _reticleGlowAnimation;

  @override
  void initState() {
    super.initState();

    if (widget.initialTargetLat != null && widget.initialTargetLng != null) {
      _targetLat = widget.initialTargetLat;
      _targetLng = widget.initialTargetLng;
      _targetName = widget.initialTargetName ?? 'Selected Post';
      _isNavigating = true;
    }

    WakelockPlus.enable();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.4).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _reticleGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _reticleGlowAnimation = Tween<double>(begin: 0.3, end: 0.7).animate(
      CurvedAnimation(parent: _reticleGlowController, curve: Curves.easeInOut),
    );

    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPostsInBackground();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _vpsTimer?.cancel();
      _vpsTimer = null;
      WakelockPlus.disable();
    } else if (state == AppLifecycleState.resumed && _arCoreInitialized) {
      _vpsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _updateVPS());
      WakelockPlus.enable();
    }
  }

  Future<void> _loadPostsInBackground() async {
    try {
      _hiddenPostIds = await ModerationService().getHiddenPostIds();
      Position? position = await Geolocator.getLastKnownPosition();
      position ??= Position(
        latitude: 33.9762,
        longitude: -118.4170,
        timestamp: DateTime.now(),
        accuracy: 100,
        altitude: 0,
        heading: 0,
        speed: 0,
        speedAccuracy: 0,
        altitudeAccuracy: 0,
        headingAccuracy: 0,
      );
      final posts = await _apiService.getNearbyPosts(
        position.latitude,
        position.longitude,
      );
      if (mounted) {
        setState(() {
          nearbyPosts = posts
              .where((p) => !p.isFlagged && !p.isExpired && !_hiddenPostIds.contains(p.id ?? ''))
              .toList();
        });
        _renderPosts();
      }
      _startPostsListener(position.latitude, position.longitude);
    } catch (e) {
      debugPrint('AR background post load failed (non-fatal): $e');
    }
  }

  // ─── Real-Time Firestore Listener ──────────────────────────────

  static const String _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';

  static String _geohashPrefix(double lat, double lng, int precision) {
    var minLat = -90.0, maxLat = 90.0;
    var minLng = -180.0, maxLng = 180.0;
    final result = StringBuffer();
    var hashVal = 0;
    var bits = 0;
    var isEven = true;

    while (result.length < precision) {
      final double mid;
      if (isEven) {
        mid = (minLng + maxLng) / 2;
        if (lng > mid) {
          hashVal = (hashVal << 1) | 1;
          minLng = mid;
        } else {
          hashVal <<= 1;
          maxLng = mid;
        }
      } else {
        mid = (minLat + maxLat) / 2;
        if (lat > mid) {
          hashVal = (hashVal << 1) | 1;
          minLat = mid;
        } else {
          hashVal <<= 1;
          maxLat = mid;
        }
      }
      isEven = !isEven;
      if (bits == 4) {
        result.write(_base32[hashVal]);
        hashVal = 0;
        bits = 0;
      } else {
        bits++;
      }
    }
    return result.toString();
  }

  /// Uses a 5-char geohash prefix (~4.9km x 4.9km) so across-the-street posts
  /// never clip across narrow 6-char tile seams.
  void _startPostsListener(double lat, double lng) {
    final prefix = _geohashPrefix(lat, lng, 5);
    if (prefix == _currentGeohashPrefix) return;

    _postsSubscription?.cancel();
    _currentGeohashPrefix = prefix;
    final upperBound = '$prefix\uf8ff';
    final now = Timestamp.now();

    _postsSubscription = FirebaseFirestore.instance
        .collection('posts')
        .where('geohash', isGreaterThanOrEqualTo: prefix)
        .where('geohash', isLessThanOrEqualTo: upperBound)
        .where('expires_at', isGreaterThan: now)
        .snapshots()
        .listen(
      (QuerySnapshot snapshot) {
        if (!mounted) return;
        final livePosts = snapshot.docs
            .map((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return Post.fromJson({...data, 'id': doc.id});
            })
            .where((p) =>
                !p.isFlagged &&
                !p.isExpired &&
                !_hiddenPostIds.contains(p.id ?? ''))
            .toList();

        setState(() => nearbyPosts = livePosts);
        _renderPosts();
      },
      onError: (e) => debugPrint('AR: Firestore listener error (non-fatal): $e'),
    );
  }

  Future<void> _updateVPS() async {
    if (!_arCoreInitialized) return;
    try {
      final pose = await arCoreController.getGeospatialPose();
      if (!mounted) return;
      setState(() => _currentPose = pose);
      if (pose != null && (pose['accuracy'] as num) < 2.5) {
        _vpsScanSeconds = 0;
        if (!_hasVpsLock) {
          setState(() {
            _hasVpsLock = true;
            _vioFailureReason = VioFailureReason.none;
          });
        }
        final lat = (pose['latitude'] as num).toDouble();
        final lng = (pose['longitude'] as num).toDouble();
        _startPostsListener(lat, lng);

        if (!_postsRendered) {
          _postsRendered = true;
        }
        // RULE 4: Call _renderPosts on every VPS lock tick so failed anchors retry
        _renderPosts();
      } else {
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
    } catch (_) {}
  }

  void onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;
    arCoreController.onNodeTap = (name) => _handleOnNodeTap(name);
    arCoreController.onPlaneTap = _handleOnPlaneTap;
    arCoreController.onRooftopAnchorResolved = _handleRooftopAnchorResolved;
    arCoreController.onTerrainAnchorResolved = _handleTerrainAnchorResolved;
    arCoreController.onCenterHitBuilding = _handleCenterHitBuilding;
    arCoreController.onCenterTargetChanged = _handleCenterTargetChanged;
    arCoreController.onCompatibilityError = _handleCompatibilityError;
    _arCoreInitialized = true;
    arCoreController.resume();
    _vpsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateVPS());
  }

  void _handleCompatibilityError(Map<String, dynamic> info) {
    if (mounted) {
      setState(() {
        _isDemoMode = info['isDemoMode'] == true;
        _demoModeReason =
            info['reason'] as String? ?? 'This device does not support spatial features.';
      });
    }
  }

  void _showVPSFallbackDialog() {
    if (_isDemoMode) return;
    _vpsTimer?.cancel();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text('Spatial Features Limited', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Visual localization is limited in this area. Point at storefronts across the street or browse existing pins on the 2D map.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _vpsScanSeconds = -9999;
              _vpsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateVPS());
            },
            child: const Text('Keep Scanning', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent,
              foregroundColor: Colors.black,
            ),
            child: const Text('Return to Map'),
          ),
        ],
      ),
    );
  }

  // ─── Center Crosshair Raycast Telemetry ─────────────────────────

  void _handleCenterHitBuilding(bool isBuilding) {
    if (_isAuraTargetingBuilding != isBuilding && mounted) {
      setState(() => _isAuraTargetingBuilding = isBuilding);
      if (isBuilding) {
        HapticFeedback.lightImpact();
        if (_isRecording) _buildingHitCount++;
      }
    }
  }

  void _handleCenterTargetChanged(Map<String, dynamic> target) {
    if (!mounted) return;
    setState(() {
      _centerTarget = target;
    });
  }

  String _buildTargetLockLabel() {
    final surface = _centerTarget?['surfaceType'] as String? ?? 'none';
    final dist = (_centerTarget?['distance'] as num?)?.toDouble() ?? 0.0;
    final distText = dist >= 1.0 ? ' · ${dist.toStringAsFixed(0)}m' : '';
    switch (surface) {
      case 'building':
        return 'Locked to Building$distText';
      case 'surface':
        return 'Locked to Object$distText';
      case 'terrain':
        return 'Locked to Ground$distText';
      default:
        return 'Anchoring Nearby';
    }
  }

  // ─── Long-Press "Point, Hold, Release" ─────────────────────────

  void _startHold() {
    final hasVPS = _currentPose != null && ((_currentPose!['accuracy'] as num?) ?? 999.0) < 3.0;
    if (!hasVPS) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pan across nearby storefronts for a moment to lock positioning.'),
          backgroundColor: Colors.black87,
        ),
      );
      return;
    }

    setState(() {
      _isHolding = true;
      _holdProgress = 0.0;
      _holdStartTime = DateTime.now();
    });

    _holdHapticTimer = Timer.periodic(const Duration(milliseconds: 140), (timer) {
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
      setState(() {
        _isHolding = false;
        _holdProgress = 0.0;
      });
      return;
    }

    HapticFeedback.heavyImpact();
    setState(() {
      _isHolding = false;
      _holdProgress = 0.0;
    });

    _dropGhostPin();
  }

  Future<void> _dropGhostPin() async {
    final user = AuthService().currentUser;
    if (user != null && user.isAnonymous && AuthService().hasDroppedFreePost) {
      HapticFeedback.heavyImpact();
      showPostLoginBottomSheet(context, isLimitReached: true);
      return;
    }

    if (_currentPose == null) return;

    final acc = (_currentPose!['accuracy'] as num?)?.toDouble() ?? 999.0;
    if (acc > 3.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Building lock required. Look at facades to localize (${acc.toStringAsFixed(1)}m).',
          ),
          backgroundColor: Colors.black87,
        ),
      );
      return;
    }

    // Perform an immediate fresh raycast from the center crosshair so pointing
    // across the street snaps directly onto the targeted building/surface!
    final freshTarget = await arCoreController.raycastCenter() ?? _centerTarget;

    final double lat = (freshTarget?['latitude'] as num?)?.toDouble() ??
        (_currentPose!['latitude'] as num).toDouble();
    final double lng = (freshTarget?['longitude'] as num?)?.toDouble() ??
        (_currentPose!['longitude'] as num).toDouble();
    final double targetAltAboveTerrain =
        ((freshTarget?['altitudeAboveTerrain'] as num?)?.toDouble() ??
                AppSizes.eyeLevelPinAltitude)
            .clamp(1.0, 18.0);
    final String anchorSurface =
        (freshTarget?['surfaceType'] as String?) ?? 'camera';
    final double hitDistance =
        (freshTarget?['distance'] as num?)?.toDouble() ?? 0.0;

    String placeName = 'Unknown Location';
    String placeCategory = anchorSurface.toUpperCase();

    try {
      final placeData = await _apiService.getPlaceFromCoordinates(lat, lng);
      if (placeData != null) {
        placeName = placeData['name'] ?? placeName;
        placeCategory = placeData['category'] ?? placeCategory;
      }
    } catch (_) {}

    if (!mounted) return;
    _showGhostPinSheet(
      lat: lat,
      lng: lng,
      pinAltAboveTerrain: targetAltAboveTerrain,
      anchorSurface: anchorSurface,
      hitDistance: hitDistance,
      placeName: placeName,
      placeCategory: placeCategory,
    );
  }

  // ─── Post Creation Bottom Sheet ─────────────────────────────────

  void _showGhostPinSheet({
    required double lat,
    required double lng,
    required double pinAltAboveTerrain,
    required String anchorSurface,
    required double hitDistance,
    required String placeName,
    required String placeCategory,
  }) {
    final contentController = TextEditingController();
    final currentUser = AuthService().currentUser;
    final bool isSignedIn = currentUser != null && !currentUser.isAnonymous;

    bool isSubmitting = false;
    String selectedPostType = 'pin';
    // Signed-in users default to Permanent neighborhood tips; guests drop a 24h live post
    // and can upgrade it to Permanent with 1 tap right after dropping.
    bool isPermanent = isSignedIn;

    final List<String> quickMessages = [
      ..._getQuickMessages(placeCategory),
      'Custom...',
    ];

    final String lockSummary = anchorSurface == 'building'
        ? 'Anchored to Building${hitDistance >= 1 ? " · ${hitDistance.toStringAsFixed(0)}m away" : ""}'
        : anchorSurface == 'surface' || anchorSurface == 'terrain'
            ? 'Anchored to Surface${hitDistance >= 1 ? " · ${hitDistance.toStringAsFixed(0)}m away" : ""}'
            : 'Anchored Nearby';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext sheetContext, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
                left: 24,
                right: 24,
                top: 20,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Target Lock Pill
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.cyanAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.my_location_rounded, color: Colors.cyanAccent, size: 14),
                          const SizedBox(width: 6),
                          Text(
                            lockSummary,
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    if (placeName.isNotEmpty && placeName != 'Unknown Location')
                      Row(
                        children: [
                          const Icon(Icons.location_pin, color: Colors.cyanAccent, size: 24),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              placeName,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),

                    // Quick Ideas
                    DropdownButtonFormField<String>(
                      decoration: InputDecoration(
                        labelText: 'Quick Idea (Optional)',
                        labelStyle: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                        filled: true,
                        fillColor: Colors.black.withValues(alpha: 0.3),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.cyanAccent),
                        ),
                      ),
                      dropdownColor: const Color(0xFF1A1A2E),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      icon: const Icon(Icons.keyboard_arrow_down, color: Colors.cyanAccent),
                      items: quickMessages
                          .map((msg) => DropdownMenuItem(value: msg, child: Text(msg)))
                          .toList(),
                      onChanged: (value) {
                        if (value != null && value != 'Custom...') {
                          setModalState(() {
                            contentController.text = value;
                          });
                        }
                      },
                      hint: const Text(
                        'Pick a prompt or write your own...',
                        style: TextStyle(color: Colors.white38, fontWeight: FontWeight.w500),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // Post Type Selection (Storefront/Eye-Level Pin vs Sky Balloon)
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: const Center(child: Text('📍 Spot Pin')),
                            selected: selectedPostType == 'pin',
                            onSelected: (val) {
                              if (val) setModalState(() => selectedPostType = 'pin');
                            },
                            selectedColor: Colors.cyanAccent,
                            backgroundColor: Colors.black45,
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: selectedPostType == 'pin' ? Colors.black : Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ChoiceChip(
                            label: const Center(child: Text('🎈 Sky Balloon')),
                            selected: selectedPostType == 'balloon',
                            onSelected: (val) {
                              if (val) setModalState(() => selectedPostType = 'balloon');
                            },
                            selectedColor: Colors.cyanAccent,
                            backgroundColor: Colors.black45,
                            labelStyle: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: selectedPostType == 'balloon' ? Colors.black : Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Lifespan Toggle: Permanent Tip vs 24h Live Moment
                    if (isSignedIn)
                      Row(
                        children: [
                          Expanded(
                            child: ChoiceChip(
                              label: const Center(child: Text('📌 Permanent')),
                              selected: isPermanent,
                              onSelected: (val) {
                                if (val) setModalState(() => isPermanent = true);
                              },
                              selectedColor: Colors.cyanAccent.withValues(alpha: 0.9),
                              backgroundColor: Colors.black45,
                              labelStyle: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: isPermanent ? Colors.black : Colors.white70,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ChoiceChip(
                              label: const Center(child: Text('⚡ 24h Live')),
                              selected: !isPermanent,
                              onSelected: (val) {
                                if (val) setModalState(() => isPermanent = false);
                              },
                              selectedColor: AppColors.liveAmber,
                              backgroundColor: Colors.black45,
                              labelStyle: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: !isPermanent ? Colors.black : Colors.white70,
                              ),
                            ),
                          ),
                        ],
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text(
                          '⚡ Guest posts stay live for 24h (sign in right after to keep forever)',
                          style: TextStyle(color: Colors.white60, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),

                    const SizedBox(height: 14),

                    // Caption Field
                    TextField(
                      controller: contentController,
                      autofocus: true,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        labelText: 'What should people know here?',
                        hintText: 'e.g. Get the cauliflower tacos, Ask for Tommy...',
                        hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
                        labelStyle: const TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.white24),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Colors.cyanAccent),
                        ),
                      ),
                      maxLines: 2,
                    ),
                    const SizedBox(height: 18),

                    isSubmitting
                        ? const Center(child: CircularProgressIndicator(color: Colors.cyanAccent))
                        : SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: ElevatedButton(
                              onPressed: () async {
                                final text = contentController.text.trim();
                                if (text.isEmpty) return;
                                setModalState(() => isSubmitting = true);

                                try {
                                  // RULE 1: Strictly terrain-relative altitude in meters!
                                  final double postAlt = selectedPostType == 'balloon'
                                      ? AppSizes.balloonAltitude
                                      : pinAltAboveTerrain;

                                  final effectivePermanent = isSignedIn && isPermanent;
                                  final newPost = Post(
                                    latitude: lat,
                                    longitude: lng,
                                    altitude: postAlt,
                                    messageContent: text,
                                    creatorId: AuthService().currentUser?.uid ?? 'anonymous',
                                    ownerId: AuthService().currentUser?.uid,
                                    visibilityType: '1-to-many',
                                    reach: 50,
                                    placeName: placeName,
                                    placeCategory: placeCategory,
                                    postType: selectedPostType,
                                    isPermanent: effectivePermanent,
                                    anchorSurface: anchorSurface,
                                    expiresAt: effectivePermanent
                                        ? Post.permanentSentinel
                                        : DateTime.now().add(const Duration(hours: 24)),
                                  );

                                  final created = await _apiService.createPost(newPost);
                                  AuthService().hasDroppedFreePost = true;

                                  if (created.isFlagged == false) {
                                    final material = ArCoreMaterial(
                                      color: AppColors.ownPost.withValues(alpha: 0.9),
                                    );
                                    final sphere = ArCoreSphere(
                                      materials: [material],
                                      radius: selectedPostType == 'balloon'
                                          ? AppSizes.balloonRadius
                                          : AppSizes.pinRadius,
                                    );
                                    final node = ArCoreNode(
                                      name: created.id ??
                                          'pin_${DateTime.now().millisecondsSinceEpoch}',
                                      shape: sphere,
                                    );

                                    // RULE 2: Always use resolveAnchorOnTerrainAsync
                                    await arCoreController.resolveAnchorOnTerrainAsync(
                                      node,
                                      lat,
                                      lng,
                                      postAlt,
                                      label: created.messageContent,
                                      isLive24h: created.isLive24h,
                                    );

                                    HapticFeedback.heavyImpact();
                                    await Future.delayed(const Duration(milliseconds: 100));
                                    HapticFeedback.heavyImpact();

                                    setState(() {
                                      nearbyPosts.add(created);
                                      _renderedPostIds.add(node.name!);
                                    });

                                    if (sheetContext.mounted) {
                                      Navigator.pop(sheetContext);
                                    }

                                    if (!mounted) return;
                                    showDialog(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (BuildContext context) {
                                        return Center(
                                          child: TweenAnimationBuilder<double>(
                                            tween: Tween<double>(begin: 0.0, end: 1.0),
                                            duration: const Duration(milliseconds: 550),
                                            curve: Curves.elasticOut,
                                            builder: (context, value, child) {
                                              return Transform.scale(
                                                scale: value,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(
                                                    horizontal: 32,
                                                    vertical: 24,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.88),
                                                    borderRadius: BorderRadius.circular(24),
                                                    border: Border.all(
                                                      color: Colors.cyanAccent.withValues(alpha: 0.6),
                                                      width: 2,
                                                    ),
                                                  ),
                                                  child: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                        Icons.check_circle_outline,
                                                        color: Colors.cyanAccent,
                                                        size: 60,
                                                      ),
                                                      const SizedBox(height: 14),
                                                      Text(
                                                        effectivePermanent
                                                            ? 'PINNED HERE'
                                                            : 'LIVE FOR 24H',
                                                        style: const TextStyle(
                                                          color: Colors.white,
                                                          fontSize: 20,
                                                          fontWeight: FontWeight.w800,
                                                          letterSpacing: 1.8,
                                                          decoration: TextDecoration.none,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 6),
                                                      Text(
                                                        lockSummary,
                                                        style: TextStyle(
                                                          color: Colors.white.withValues(alpha: 0.72),
                                                          fontSize: 13,
                                                          fontWeight: FontWeight.w500,
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

                                    Future.delayed(const Duration(milliseconds: 1600), () {
                                      if (mounted && Navigator.canPop(context)) {
                                        Navigator.pop(context);
                                        final user = AuthService().currentUser;
                                        if (user != null && user.isAnonymous && created.id != null) {
                                          _showSaveItToast(created.id!);
                                        }
                                      }
                                    });
                                  } else {
                                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: const Text(
                                            'Post submitted for moderation review.',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          backgroundColor: Colors.orange.shade800,
                                          behavior: SnackBarBehavior.floating,
                                        ),
                                      );
                                    }
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Could not drop post: $e')),
                                    );
                                  }
                                  setModalState(() => isSubmitting = false);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.cyanAccent,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                elevation: 6,
                              ),
                              child: Text(
                                isSignedIn && isPermanent
                                    ? '📌 Pin Permanently'
                                    : '⚡ Drop 24h Post',
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ),
                    const SizedBox(height: 26),
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
    if (cat.contains('restaurant') || cat.contains('food') || cat.contains('cafe') || cat.contains('bakery')) {
      return ['Must-order dish:', 'Best seat in the house', 'Skip the line tip:'];
    } else if (cat.contains('salon') || cat.contains('spa') || cat.contains('store') || cat.contains('shop')) {
      return ['Ask for...', 'Hidden gem right here', 'Local tip:'];
    } else if (cat.contains('park') || cat.contains('recreation')) {
      return ['Hidden playground!', 'Doggie bags here', 'Great walking spot'];
    }
    return ['Hidden gem!', 'Insider tip:', 'Meet me here'];
  }

  void _showSaveItToast(String createdPostId) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 7),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 90, left: 20, right: 20),
        backgroundColor: const Color(0xFF161B25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.cyanAccent.withValues(alpha: 0.45)),
        ),
        content: const Text(
          'Live for 24h! Want this tip pinned forever?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        action: SnackBarAction(
          label: 'Keep Forever',
          textColor: Colors.cyanAccent,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            showPostLoginBottomSheet(
              context,
              pendingPostIdToClaim: createdPostId,
            );
          },
        ),
      ),
    );
  }

  // ─── Anchor & Tap Handlers ──────────────────────────────────────

  void _handleTerrainAnchorResolved(String name, bool success, String? state) {
    if (!success) {
      // RULE 4: Remove from rendered set so _renderPosts() retries on next VPS tick.
      _renderedPostIds.remove(name);
    }
  }

  void _handleRooftopAnchorResolved(String name, bool success, String? state) {
    if (!success) {
      _renderedPostIds.remove(name);
    }
  }

  Future<void> _executePostCta(Post post) async {
    try {
      if (post.actionUrl != null && post.actionUrl!.trim().isNotEmpty) {
        final uri = Uri.tryParse(post.actionUrl!.trim());
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          return;
        }
      }

      final lat = post.latitude;
      final lng = post.longitude;
      final Uri mapsUri = Platform.isIOS
          ? Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=w')
          : Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=walking');
      await launchUrl(mapsUri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _handleOnNodeTap(String name) {
    if (_isDialogShowing) return;
    try {
      final post = nearbyPosts.firstWhere((p) {
        final index = nearbyPosts.indexOf(p);
        return (p.id ?? 'temp_$index') == name;
      });
      final postId = post.id ?? name;
      _apiService.viewPost(postId);
      _isDialogShowing = true;

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF161B25),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: post.isLive24h
                          ? AppColors.liveAmber.withValues(alpha: 0.16)
                          : Colors.cyanAccent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      post.isLive24h ? '⚡ 24h Live' : '📌 Pinned Tip',
                      style: TextStyle(
                        color: post.isLive24h ? AppColors.liveAmber : Colors.cyanAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (post.placeName != null &&
                      post.placeName!.isNotEmpty &&
                      post.placeName != 'Unknown Location') ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        post.placeName!,
                        style: const TextStyle(color: Color(0xFF8896B0), fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                post.messageContent,
                style: const TextStyle(
                  color: Color(0xFFF0F4FF),
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _executePostCta(post);
                },
                icon: const Icon(Icons.directions_walk_rounded, size: 18),
                label: Text(
                  (post.ctaText != null && post.ctaText!.isNotEmpty)
                      ? post.ctaText!
                      : 'Walk Here',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black,
                  minimumSize: const Size.fromHeight(44),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.send, color: Colors.cyanAccent),
              tooltip: 'Share',
              onPressed: () {
                final place =
                    (post.placeName != null && post.placeName != 'Unknown Location')
                        ? post.placeName!
                        : 'this spot';
                final mapsUrl = 'https://maps.google.com/?q=${post.latitude},${post.longitude}';
                SharePlus.instance.share(
                  ShareParams(
                    text:
                        '📍 Found on Post Spatial at $place: "${post.messageContent}"\n\n$mapsUrl\n\nSee it in AR: https://get-post.co/scan',
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.visibility_off_outlined, color: Color(0xFF8896B0)),
              tooltip: 'Hide post',
              onPressed: () async {
                Navigator.pop(ctx);
                await ModerationService().hidePost(postId);
                _hiddenPostIds.add(postId);
                await arCoreController.removeNode(nodeName: postId);
                _renderedPostIds.remove(postId);
                if (mounted) {
                  setState(() => nearbyPosts.removeWhere((p) => (p.id ?? '') == postId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Post hidden.')),
                  );
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.flag_outlined, color: Color(0xFFFF5252)),
              tooltip: 'Report post',
              onPressed: () async {
                Navigator.pop(ctx);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    backgroundColor: const Color(0xFF161B25),
                    title: const Text(
                      'Report post?',
                      style: TextStyle(color: Color(0xFFF0F4FF)),
                    ),
                    content: const Text(
                      'This post will be reviewed right away. Thank you for keeping Post safe.',
                      style: TextStyle(color: Color(0xFF8896B0)),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(c, false),
                        child: const Text('Cancel', style: TextStyle(color: Color(0xFF8896B0))),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(c, true),
                        child: const Text('Report', style: TextStyle(color: Color(0xFFFF5252))),
                      ),
                    ],
                  ),
                );
                if (confirmed == true) {
                  await ModerationService().reportPost(postId);
                  await ModerationService().hidePost(postId);
                  _hiddenPostIds.add(postId);
                  await arCoreController.removeNode(nodeName: postId);
                  _renderedPostIds.remove(postId);
                  if (mounted) {
                    setState(() => nearbyPosts.removeWhere((p) => (p.id ?? '') == postId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Post reported. Thank you.')),
                    );
                  }
                }
              },
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: Color(0xFF4F8EF7))),
            ),
          ],
        ),
      ).then((_) => _isDialogShowing = false);
    } catch (_) {}
  }

  void _handleOnPlaneTap(List<ArCoreHitTestResult> hits) async {}

  void _renderPosts() {
    if (!_arCoreInitialized) return;
    int index = 0;
    for (final post in nearbyPosts) {
      final String postId = post.id ?? 'temp_$index';
      if (_hiddenPostIds.contains(postId)) {
        index++;
        continue;
      }
      if (_renderedPostIds.contains(postId)) {
        index++;
        continue;
      }
      _renderedPostIds.add(postId);

      final currentUserId = AuthService().currentUser?.uid ?? '';
      final isOwn = post.creatorId == currentUserId || post.ownerId == currentUserId;
      final material = ArCoreMaterial(
        color: (isOwn ? AppColors.ownPost : AppColors.othersPost).withValues(alpha: 0.85),
      );
      final radius = post.postType == 'balloon' ? AppSizes.balloonRadius : AppSizes.pinRadius;
      final sphere = ArCoreSphere(materials: [material], radius: radius);
      final node = ArCoreNode(name: postId, shape: sphere);

      // RULE 3: Guard legacy negative GPS altitudes
      double altOffset = post.altitude;
      if (altOffset < 0) {
        altOffset = post.postType == 'balloon'
            ? AppSizes.balloonAltitude
            : AppSizes.pinAltitude;
      }

      // RULE 2: Always render via resolveAnchorOnTerrainAsync (+ floating 3D label!)
      arCoreController.resolveAnchorOnTerrainAsync(
        node,
        post.latitude,
        post.longitude,
        altOffset,
        label: post.messageContent,
        isLive24h: post.isLive24h,
      );
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
    _debugLog.writeln('Platform: ${Platform.operatingSystem} | Package: com.post.spatial');
    _debugLog.writeln('');

    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
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
      final lat = (_currentPose!['latitude'] as num).toStringAsFixed(4);
      final lng = (_currentPose!['longitude'] as num).toStringAsFixed(4);
      final surface = _centerTarget?['surfaceType'] ?? 'none';
      final dist = ((_centerTarget?['distance'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(1);
      _debugLog.writeln('[${t}s] VPS: acc=${acc}m lat=$lat lng=$lng | TARGET: $surface (${dist}m)');
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
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Icon(Icons.bug_report, color: Colors.redAccent, size: 28),
                SizedBox(width: 8),
                Text(
                  'Black Box Captured',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              height: 200,
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: SingleChildScrollView(
                child: Text(
                  logText,
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  SharePlus.instance.share(ShareParams(text: logText, subject: 'Post Bug Report'));
                },
                icon: const Icon(Icons.send_rounded),
                label: const Text(
                  'Send to Developer',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Dismiss', style: TextStyle(color: Colors.white38)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _vpsTimer?.cancel();
    _holdHapticTimer?.cancel();
    _recordingTimer?.cancel();
    _postsSubscription?.cancel();
    _pulseController.dispose();
    _reticleGlowController.dispose();
    if (_arCoreInitialized) arCoreController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ─── BUILD ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          ArCoreView(
            key: _arCoreKey,
            onArCoreViewCreated: onArCoreViewCreated,
            enableTapRecognizer: true,
            enableUpdateListener: true,
            enablePlaneRenderer: false,
            debug: kDebugMode,
          ),
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: _overlayTrigger,
              builder: (context, _, _) {
                final hasVPS = _currentPose != null &&
                    ((_currentPose!['accuracy'] as num?) ?? 999.0) < 3.0;
                final hasSurfaceTarget = (_centerTarget?['hasTarget'] == true) && hasVPS;

                return GestureDetector(
                  onLongPressStart: (_) => _startHold(),
                  onLongPressEnd: (_) => _releaseHold(),
                  child: Stack(
                    children: [
                      if (!_isDemoMode)
                        ArOnboardingOverlay(
                          targetLat: _isNavigating ? _targetLat : null,
                          targetLng: _isNavigating ? _targetLng : null,
                          propertyName: _isNavigating ? _targetName : '',
                          isTracking: _hasVpsLock,
                          failureReason: _vioFailureReason,
                        ),

                      if (_isDemoMode)
                        Container(
                          color: const Color(0xFF0A0E1A),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(40),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.smartphone, color: Colors.cyanAccent, size: 64),
                                  const SizedBox(height: 24),
                                  const Text(
                                    'Spatial Features Not Available',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    _demoModeReason,
                                    style: const TextStyle(color: Colors.cyanAccent, fontSize: 15),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 32),
                                  OutlinedButton.icon(
                                    onPressed: () => Navigator.pop(context),
                                    icon: const Icon(Icons.arrow_back, color: Colors.cyanAccent),
                                    label: const Text(
                                      'Back to Map',
                                      style: TextStyle(color: Colors.cyanAccent),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                      // ── CENTER CROSSHAIR RETICLE ──
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
                            padding: const EdgeInsets.all(36.0),
                            child: AnimatedBuilder(
                              animation: _reticleGlowAnimation,
                              builder: (context, child) {
                                final isLocked = hasVPS && (hasSurfaceTarget || _isAuraTargetingBuilding);
                                return Icon(
                                  Icons.location_pin,
                                  color: isLocked
                                      ? Colors.cyanAccent
                                      : (hasVPS ? Colors.white : Colors.white54),
                                  size: isLocked ? 48 : 38,
                                  shadows: isLocked
                                      ? [
                                          Shadow(
                                            color: Colors.cyanAccent.withValues(alpha: 0.65),
                                            blurRadius: 22,
                                          ),
                                        ]
                                      : [],
                                );
                              },
                            ),
                          ),
                        ),
                      ),

                      if (!hasVPS && !_isDemoMode && _vpsScanSeconds > 2 && _vpsScanSeconds < 15)
                        Positioned(
                          bottom: 120,
                          left: 24,
                          right: 24,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5)),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.camera_alt_outlined, color: Colors.cyanAccent, size: 28),
                                SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    'Scanning...\nSlowly pan across nearby building facades to lock positioning.',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      // ── GHOST SPHERE WHEN HOLDING ──
                      if (_isHolding && hasVPS)
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
                                  color: Colors.cyanAccent.withValues(alpha: 0.2 + _holdProgress * 0.3),
                                  border: Border.all(color: Colors.cyanAccent, width: 2),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.cyanAccent.withValues(
                                        alpha: 0.3 + _holdProgress * 0.4,
                                      ),
                                      blurRadius: 20 + _holdProgress * 30,
                                      spreadRadius: 5 + _holdProgress * 15,
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),

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

                      if (_isAuraTargetingBuilding && hasVPS && !_isHolding)
                        IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: Colors.cyanAccent.withValues(alpha: 0.25),
                                width: 3,
                              ),
                            ),
                          ),
                        ),

                      // ── Top bar ──
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.map_outlined, color: Colors.white, size: 28),
                                  onPressed: () => Navigator.pop(context),
                                  tooltip: 'Back to Map',
                                ),
                              ),
                              const Spacer(),
                              Container(
                                decoration: BoxDecoration(
                                  color: _isRecording
                                      ? Colors.redAccent.withValues(alpha: 0.3)
                                      : Colors.black54,
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
                              const SizedBox(width: 8),
                              if (_currentPose != null &&
                                  ((_currentPose!['accuracy'] as num?) ?? 999.0) < 900.0)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: hasVPS
                                        ? Colors.cyanAccent.withValues(alpha: 0.15)
                                        : Colors.redAccent.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: hasVPS
                                          ? Colors.cyanAccent.withValues(alpha: 0.4)
                                          : Colors.redAccent.withValues(alpha: 0.4),
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
                                      const SizedBox(width: 6),
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

                      // ── Bottom Live Target Lock Pill + Instruction Hint ──
                      Positioned(
                        bottom: 30,
                        left: 0,
                        right: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (hasVPS && !_isHolding)
                              Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0D1220).withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: _isAuraTargetingBuilding
                                        ? Colors.cyanAccent.withValues(alpha: 0.7)
                                        : Colors.white24,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _isAuraTargetingBuilding
                                          ? Icons.apartment_rounded
                                          : Icons.adjust_rounded,
                                      size: 14,
                                      color: Colors.cyanAccent,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _buildTargetLockLabel(),
                                      style: const TextStyle(
                                        color: Colors.cyanAccent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                _isHolding
                                    ? 'Hold to lock pin... ${(_holdProgress * 100).toInt()}%'
                                    : hasVPS
                                        ? 'Aim at any building or spot & hold (or tap pin)'
                                        : 'Scanning for VPS lock...',
                                style: const TextStyle(color: Colors.white70, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
