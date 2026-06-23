import 'package:flutter/material.dart';

/// Central color and theme constants for Post Spatial.
/// All UI files import from here. Never hardcode colors elsewhere.
/// iOS and Android share this file identically — one source of truth.
class AppColors {
  AppColors._();

  // ── AR Post Colors ──────────────────────────────────────────────
  /// Teal: own posts (dropped by the current user)
  static const Color ownPost = Color(0xFF00E5FF);

  /// Violet: posts from other users
  static const Color othersPost = Color(0xFFB388FF);

  // ── UI Accent ───────────────────────────────────────────────────
  /// Primary cyan accent — ghost pin, borders, badges
  static const Color accent = Color(0xFF00E5FF);

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
  // Changing these will cause posts to render underground or at wrong height.
  static const double balloonAltitude = 15.0;
  static const double pinAltitude = 0.0;
}
