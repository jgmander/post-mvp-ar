import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';

/// Handles user-facing content moderation: reporting and hiding posts.
/// - Reports route through Cloud Run (`POST /posts/{id}/report`) so Gemini 2.5 Flash
///   auto-removes confirmed unsafe content, falling back to Firestore `reports/` if offline.
/// - Hidden posts are stored locally in SharedPreferences.
class ModerationService {
  static final ModerationService _instance = ModerationService._internal();
  factory ModerationService() => _instance;
  ModerationService._internal();

  static const _hiddenKey = 'hidden_post_ids';

  // ── Report ─────────────────────────────────────────────────────

  Future<void> reportPost(String postId, {String reason = 'inappropriate'}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final handledByBackend = await ApiService().reportPost(postId);
    if (handledByBackend) return;

    // Fallback if backend is unreachable
    await FirebaseFirestore.instance.collection('reports').add({
      'postId': postId,
      'reporterId': user.uid,
      'reason': reason,
      'timestamp': FieldValue.serverTimestamp(),
      'status': 'pending',
    });
  }

  // ── Hide (local) ───────────────────────────────────────────────

  Future<void> hidePost(String postId) async {
    final prefs = await SharedPreferences.getInstance();
    final hidden = prefs.getStringList(_hiddenKey) ?? [];
    if (!hidden.contains(postId)) {
      hidden.add(postId);
      await prefs.setStringList(_hiddenKey, hidden);
    }
  }

  Future<Set<String>> getHiddenPostIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_hiddenKey) ?? []).toSet();
  }
}
