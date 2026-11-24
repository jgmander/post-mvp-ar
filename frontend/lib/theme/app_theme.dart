import 'package:flutter/material.dart';

/// Central color and theme constants for Post Spatial (v1.1.1 Electric Post Blue).
/// All UI files import from here. Never hardcode colors elsewhere.
/// iOS and Android share this file identically — one source of truth.
class AppColors {
  AppColors._();

  // ── AR Post Colors ──────────────────────────────────────────────
  /// Signature Electric Post Blue: own posts & brand badge
  static const Color ownPost = Color(0xFF1A8CFF);

  /// Electric Ultramarine-Violet: posts from other users
  static const Color othersPost = Color(0xFF7B61FF);

  // ── UI Accent ───────────────────────────────────────────────────
  /// Luminous Electric Post Blue accent — reticle, shutter, badges
  static const Color accent = Color(0xFF2997FF);

  /// Crisp vinyl white — sticker borders & sky-contrast rims
  static const Color vinylWhite = Color(0xFFFFFFFF);

  /// Warm amber accent for 24h Live ephemeral moments
  static const Color liveAmber = Color(0xFFFFB82E);

  /// Success green
  static const Color success = Color(0xFF69F0AE);

  /// Error / warning red
  static const Color error = Color(0xFFFF5252);

  // ── Backgrounds ─────────────────────────────────────────────────
  static const Color darkSheet = Color(0xFF1A1A2E);
  static const Color darkCard = Color(0xFF12121F);
}

class AppSizes {
  AppSizes._();

  // ── AR Sphere Radii ─────────────────────────────────────────────
  static const double balloonRadius = 2.5;
  static const double pinRadius = 0.6;

  // ── AR Altitude Offsets (terrain-relative — DO NOT CHANGE) ──────
  // See .agent/agent_rules.md RULE 1 before touching these values.
  // These are meters ABOVE the terrain surface, NOT GPS/WGS-84 altitude.
  static const double balloonAltitude = 15.0;
  static const double pinAltitude = 0.0;          // Legacy clamp baseline
  static const double eyeLevelPinAltitude = 1.4;  // Eye/chest height for new pins
}
