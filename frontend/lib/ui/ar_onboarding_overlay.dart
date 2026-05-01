import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ArOnboardingOverlay
//
// Implements a two-phase UX pipeline to bridge the gap between AR session
// launch and the first confirmed VPS TRACKING state.
//
// Phase 1 — Instant Compass:
//   • Streams live device GPS via geolocator.
//   • Streams native OS-level compass heading via flutter_compass.
//   • Calculates the bearing delta between the user and the target property.
//   • Renders a glowing directional indicator pointing toward the property.
//
// Phase 2 — VIO Coaching:
//   • Renders pill-shaped toasts driven by the ARCore TrackingFailureReason
//     that the parent widget passes down as a plain string.
//
// Phase 3 — Handoff:
//   • Fades itself out the moment isTracking == true.
//   • Once fully invisible, disposes its compass and GPS streams.
//
// CONSTRAINT: This widget is purely a UI overlay. It NEVER touches the
// ArCoreView, its controller, or any native session lifecycle methods.
// ─────────────────────────────────────────────────────────────────────────────

/// The reason ARCore tracking is currently paused, translated from the native
/// MethodChannel payload. The parent [ArView] must set this whenever the
/// `onTrackingStateChanged` callback fires with a non-TRACKING reason.
enum VioFailureReason {
  none,
  excessiveMotion,
  insufficientFeatures,
}

class ArOnboardingOverlay extends StatefulWidget {
  /// The real-world latitude of the target property.
  final double targetLat;

  /// The real-world longitude of the target property.
  final double targetLng;

  /// The display name of the target property, shown in the compass label.
  final String propertyName;

  /// Set to [true] the moment the ARCore session reports TRACKING state.
  /// Triggers the Phase 3 fade-out.
  final bool isTracking;

  /// The current VIO failure reason — drives Phase 2 coaching toasts.
  final VioFailureReason failureReason;

  const ArOnboardingOverlay({
    Key? key,
    required this.targetLat,
    required this.targetLng,
    required this.propertyName,
    required this.isTracking,
    this.failureReason = VioFailureReason.none,
  }) : super(key: key);

  @override
  State<ArOnboardingOverlay> createState() => _ArOnboardingOverlayState();
}

class _ArOnboardingOverlayState extends State<ArOnboardingOverlay>
    with TickerProviderStateMixin {
  // ── State ──────────────────────────────────────────────────────────────────
  double? _deviceHeading;   // degrees: 0–360, north-up, from flutter_compass
  Position? _userPosition;  // live GPS from geolocator
  StreamSubscription<CompassEvent>? _compassSub;
  StreamSubscription<Position>? _locationSub;

  // ── Animations ─────────────────────────────────────────────────────────────
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  late AnimationController _arrowBobController;
  late Animation<double> _arrowBobAnimation;

  // ── Coaching toast visibility ──────────────────────────────────────────────
  late AnimationController _toastController;
  late Animation<double> _toastAnimation;
  VioFailureReason _lastRenderedReason = VioFailureReason.none;

  @override
  void initState() {
    super.initState();

    // Phase 3: fade-out controller (0 = fully visible, 1 = fully gone)
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeInOut,
    );

    // Pulse ring behind the compass arrow
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Subtle vertical bob on the arrow icon
    _arrowBobController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _arrowBobAnimation = Tween<double>(begin: -4.0, end: 4.0).animate(
      CurvedAnimation(parent: _arrowBobController, curve: Curves.easeInOut),
    );

    // Toast slide-in controller
    _toastController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _toastAnimation = CurvedAnimation(
      parent: _toastController,
      curve: Curves.easeOutCubic,
    );

    _startCompass();
    _startLocation();
  }

  void _startCompass() {
    if (FlutterCompass.events == null) {
      // Device has no magnetometer (e.g. simulator) — fail silently.
      return;
    }
    _compassSub = FlutterCompass.events!.listen((CompassEvent event) {
      if (mounted && event.heading != null) {
        setState(() => _deviceHeading = event.heading!);
      }
    });
  }

  void _startLocation() async {
    // Request permission once — geolocator already has it for AR, but we call
    // this defensively so the overlay works standalone.
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) return;

    // Get an immediate coarse fix first so the arrow shows instantly.
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null && mounted) {
      setState(() => _userPosition = lastKnown);
    }

    // Then stream live updates at high accuracy (ARCore needs it anyway).
    _locationSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 2, // update every 2 metres of movement
      ),
    ).listen((Position pos) {
      if (mounted) setState(() => _userPosition = pos);
    });
  }

  @override
  void didUpdateWidget(ArOnboardingOverlay old) {
    super.didUpdateWidget(old);

    // Phase 3: trigger fade-out when parent reports TRACKING
    if (widget.isTracking && !old.isTracking) {
      _fadeController.forward().then((_) {
        // Cancel streams once invisible — don't burn sensors after lock
        _compassSub?.cancel();
        _locationSub?.cancel();
      });
    }

    // Phase 2: animate coaching toast in/out when failure reason changes
    if (widget.failureReason != old.failureReason) {
      if (widget.failureReason != VioFailureReason.none) {
        setState(() => _lastRenderedReason = widget.failureReason);
        _toastController.forward();
      } else {
        _toastController.reverse();
      }
    }
  }

  @override
  void dispose() {
    _compassSub?.cancel();
    _locationSub?.cancel();
    _fadeController.dispose();
    _pulseController.dispose();
    _arrowBobController.dispose();
    _toastController.dispose();
    super.dispose();
  }

  // ── Bearing Calculation ────────────────────────────────────────────────────

  /// Returns the angle (in radians) that the compass arrow must be rotated
  /// to point toward the target property, relative to device screen-up.
  double? _computeArrowRotationRadians() {
    if (_userPosition == null || _deviceHeading == null) return null;

    // True bearing from user's GPS to the target property (0–360, clockwise from north)
    final trueBearing = Geolocator.bearingBetween(
      _userPosition!.latitude,
      _userPosition!.longitude,
      widget.targetLat,
      widget.targetLng,
    );

    // Delta = bearing to target minus where the phone is currently facing.
    // A positive delta means the target is clockwise from the phone's heading.
    final delta = trueBearing - _deviceHeading!;

    return delta * (math.pi / 180.0);
  }

  // ── Distance Label ─────────────────────────────────────────────────────────

  String _distanceLabel() {
    if (_userPosition == null) return '';
    final metres = Geolocator.distanceBetween(
      _userPosition!.latitude,
      _userPosition!.longitude,
      widget.targetLat,
      widget.targetLng,
    );
    if (metres < 1000) return '${metres.toStringAsFixed(0)}m away';
    return '${(metres / 1000).toStringAsFixed(1)}km away';
  }

  // ── Coaching Text ──────────────────────────────────────────────────────────

  String _coachingText(VioFailureReason reason) {
    switch (reason) {
      case VioFailureReason.excessiveMotion:
        return 'Move phone slower to calibrate.';
      case VioFailureReason.insufficientFeatures:
        return 'Point camera at buildings.';
      case VioFailureReason.none:
        return '';
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final arrowRadians = _computeArrowRotationRadians();
    final noSensor = FlutterCompass.events == null;

    return FadeTransition(
      // Fades OUT (opacity goes 1→0) as _fadeAnimation goes 0→1
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeAnimation),
      child: IgnorePointer(
        // Once fully faded, absorb no touches so the AR view beneath is clear
        ignoring: widget.isTracking,
        child: Stack(
          children: [
            // ── Phase 1: Compass Indicator ────────────────────────────────
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Pulsing glow ring
                  AnimatedBuilder(
                    animation: _pulseAnimation,
                    builder: (context, child) {
                      return Container(
                        width: 160,
                        height: 160,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.cyanAccent
                                  .withValues(alpha: 0.15 * _pulseAnimation.value),
                              blurRadius: 60 * _pulseAnimation.value,
                              spreadRadius: 20 * _pulseAnimation.value,
                            ),
                          ],
                        ),
                        child: child,
                      );
                    },
                    child: _buildCompassDial(arrowRadians, noSensor),
                  ),

                  const SizedBox(height: 20),

                  // Property name label
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.cyanAccent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.propertyName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (_userPosition != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            _distanceLabel(),
                            style: TextStyle(
                              color: Colors.cyanAccent.withValues(alpha: 0.8),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // Scanning status
                  Text(
                    'Scanning environment…',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),

            // ── Phase 2: VIO Coaching Toast ───────────────────────────────
            Positioned(
              top: 100,
              left: 24,
              right: 24,
              child: FadeTransition(
                opacity: _toastAnimation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.5),
                    end: Offset.zero,
                  ).animate(_toastAnimation),
                  child: _buildCoachingToast(_lastRenderedReason),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompassDial(double? arrowRadians, bool noSensor) {
    return Container(
      width: 160,
      height: 160,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.black.withValues(alpha: 0.55),
        border: Border.all(
          color: Colors.cyanAccent.withValues(alpha: 0.35),
          width: 1.5,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Crosshair ring
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.08),
                width: 1,
              ),
            ),
          ),

          // Cardinal tick marks
          ...List.generate(8, (i) {
            final angle = i * math.pi / 4;
            return Transform.rotate(
              angle: angle,
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 16),
                  width: 1.5,
                  height: i % 2 == 0 ? 10 : 6,
                  color: Colors.white.withValues(alpha: i % 2 == 0 ? 0.4 : 0.2),
                ),
              ),
            );
          }),

          // The directional arrow (or a no-sensor fallback)
          if (noSensor)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sensors_off, color: Colors.white38, size: 28),
                const SizedBox(height: 4),
                Text(
                  'No compass',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                  ),
                ),
              ],
            )
          else if (arrowRadians == null)
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.cyanAccent,
              ),
            )
          else
            AnimatedBuilder(
              animation: _arrowBobAnimation,
              builder: (ctx, child) {
                return Transform.translate(
                  offset: Offset(0, _arrowBobAnimation.value),
                  child: Transform.rotate(
                    angle: arrowRadians,
                    child: child,
                  ),
                );
              },
              child: _buildArrow(),
            ),

          // "N" north label at the top of the dial
          Positioned(
            top: 14,
            child: Text(
              'N',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArrow() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Glowing arrowhead
        ShaderMask(
          shaderCallback: (Rect bounds) {
            return const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.cyanAccent, Color(0xFF00E5FF)],
            ).createShader(bounds);
          },
          child: const Icon(
            Icons.navigation_rounded,
            size: 52,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildCoachingToast(VioFailureReason reason) {
    if (reason == VioFailureReason.none) return const SizedBox.shrink();

    final bool isMotion = reason == VioFailureReason.excessiveMotion;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: isMotion
            ? Colors.orange.withValues(alpha: 0.15)
            : Colors.blueAccent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: isMotion
              ? Colors.orange.withValues(alpha: 0.6)
              : Colors.blueAccent.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: isMotion
                ? Colors.orange.withValues(alpha: 0.15)
                : Colors.blueAccent.withValues(alpha: 0.15),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isMotion ? Icons.slow_motion_video_rounded : Icons.domain_rounded,
            color: isMotion ? Colors.orange : Colors.blueAccent,
            size: 18,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _coachingText(reason),
              style: TextStyle(
                color: isMotion ? Colors.orange : Colors.blueAccent,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
