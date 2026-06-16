import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles user-facing content moderation: reporting and hiding posts.
/// - Reports are written to Firestore `reports/` (admin-only read).
/// - Hidden posts are stored locally in SharedPreferences.
class ModerationService {
  static final ModerationService _instance = ModerationService._internal();
  factory ModerationService() => _instance;
  ModerationService._internal();

  static const _hiddenKey = 'hidden_post_ids';

  // ── Report ─────────────────────────────────────────────────────

  /// Writes a report document to Firestore.
  /// Firestore rules enforce: auth required, reporterId == uid, status == pending.
  Future<void> reportPost(String postId, {String reason = 'inappropriate'}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('reports').add({
      'postId': postId,
      'reporterId': user.uid,
      'reason': reason,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'pending',
    });
  }

  // ── Hide (local) ───────────────────────────────────────────────

  /// Persists a hidden post ID to SharedPreferences.
  Future<void> hidePost(String postId) async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getStringList(_hiddenKey) ?? [];
    if (!hidden.contains(postId)) {
      hidden.add(postId);
      await prefs.setStringList(_hiddenKey, hidden);
    }
  }

  /// Returns all hidden post IDs as a Set for O(1) lookup.
  Future<Set<String>> getHiddenPostIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_hiddenKey) ?? []).toSet();
  }
}
