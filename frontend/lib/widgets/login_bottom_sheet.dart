import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../screens/admin_dashboard.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import 'auth_collision_sheet.dart';

Future<void> showPostLoginBottomSheet(
  BuildContext context, {
  bool isLimitReached = false,
  String? pendingPostIdToClaim,
  VoidCallback? onPostClaimed,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => PostLoginBottomSheet(
      parentContext: context,
      isLimitReached: isLimitReached,
      pendingPostIdToClaim: pendingPostIdToClaim,
      onPostClaimed: onPostClaimed,
    ),
  );
}

class PostLoginBottomSheet extends StatefulWidget {
  final BuildContext parentContext;
  final bool isLimitReached;
  final String? pendingPostIdToClaim;
  final VoidCallback? onPostClaimed;

  const PostLoginBottomSheet({
    super.key,
    required this.parentContext,
    this.isLimitReached = false,
    this.pendingPostIdToClaim,
    this.onPostClaimed,
  });

  @override
  State<PostLoginBottomSheet> createState() => _PostLoginBottomSheetState();
}

class _PostLoginBottomSheetState extends State<PostLoginBottomSheet> {
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();
  int _adminTapCount = 0;
  bool _loading = false;
  String? _emailError;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _claimPendingPostIfNeeded(String? priorAnonUid) async {
    final postId = widget.pendingPostIdToClaim;
    if (postId == null || postId.isEmpty) return;
    final updated = await ApiService().updatePost(
      postId,
      isPermanent: true,
      claimFromUid: priorAnonUid,
    );
    if (updated != null) {
      widget.onPostClaimed?.call();
    }
  }

  Future<void> _handleOAuth(Future<void> Function() authAction, String providerLabel) async {
    final current = AuthService().currentUser;
    final priorAnonUid = (current != null && current.isAnonymous) ? current.uid : null;

    setState(() {
      _loading = true;
      _emailError = null;
    });

    try {
      await authAction();
      await _claimPendingPostIfNeeded(priorAnonUid);
      if (mounted) {
        Navigator.pop(context);
      }
      if (widget.parentContext.mounted) {
        final msg = widget.pendingPostIdToClaim != null
            ? 'Signed in with $providerLabel! Your post is now pinned permanently.'
            : 'Signed in with $providerLabel!';
        ScaffoldMessenger.of(widget.parentContext).showSnackBar(
          SnackBar(content: Text(msg)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
      }
      if (e is FirebaseAuthException &&
          (e.code == 'account-exists-with-different-credential' ||
              e.code == 'email-already-in-use')) {
        final email = AuthService().lastCollisionEmail ?? '';
        if (email.isNotEmpty) {
          final providers = await AuthService().getProvidersForEmail(email);
          if (mounted) {
            Navigator.pop(context);
          }
          if (widget.parentContext.mounted) {
            showModalBottomSheet(
              context: widget.parentContext,
              backgroundColor: Colors.transparent,
              isScrollControlled: true,
              builder: (_) => AuthCollisionBottomSheet(
                email: email,
                availableProviders: providers,
              ),
            );
            return;
          }
        }
      }
      if (widget.parentContext.mounted) {
        ScaffoldMessenger.of(widget.parentContext).showSnackBar(
          SnackBar(content: Text('Sign-in cancelled or failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isClaiming = widget.pendingPostIdToClaim != null;
    final title = widget.isLimitReached
        ? "You've used your free guest post"
        : isClaiming
            ? 'Keep This Post Forever'
            : 'Claim Your Identity';
    final subtitle = widget.isLimitReached
        ? 'Sign in to drop unlimited neighborhood tips and live moments.'
        : isClaiming
            ? 'Sign in with 1 tap so this post stays permanently anchored here.'
            : 'Sign in to drop permanent neighborhood tips and manage your posts.';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF161B25),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        left: 24,
        right: 24,
        top: 14,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFF252D3F),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 22),
            const Icon(Icons.push_pin_rounded, color: Color(0xFF00E5FF), size: 44),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFFF0F4FF),
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF8896B0),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _loading
                    ? null
                    : () => _handleOAuth(AuthService().signInWithApple, 'Apple'),
                icon: const Icon(Icons.apple_rounded, color: Colors.white, size: 26),
                label: const Text(
                  'Continue with Apple',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: Colors.white24, width: 1),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _loading
                    ? null
                    : () => _handleOAuth(AuthService().linkWithGoogle, 'Google'),
                icon: const Icon(Icons.g_mobiledata_rounded, color: Color(0xFF161B25), size: 32),
                label: const Text(
                  'Continue with Google',
                  style: TextStyle(color: Color(0xFF161B25), fontSize: 16, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF0F4FF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Row(
                children: [
                  Expanded(child: Divider(color: Color(0xFF252D3F))),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or', style: TextStyle(color: Color(0xFF4A607A), fontSize: 12)),
                  ),
                  Expanded(child: Divider(color: Color(0xFF252D3F))),
                ],
              ),
            ),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Color(0xFFF0F4FF), fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Email',
                hintStyle: const TextStyle(color: Color(0xFF4A607A)),
                filled: true,
                fillColor: const Color(0xFF141F35),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              style: const TextStyle(color: Color(0xFFF0F4FF), fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Password',
                hintStyle: const TextStyle(color: Color(0xFF4A607A)),
                filled: true,
                fillColor: const Color(0xFF141F35),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
            if (_emailError != null) ...[
              const SizedBox(height: 6),
              Text(_emailError!, style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12)),
            ],
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _loading
                    ? null
                    : () async {
                        final parentCtx = widget.parentContext;
                        final current = AuthService().currentUser;
                        final priorAnonUid =
                            (current != null && current.isAnonymous) ? current.uid : null;
                        setState(() {
                          _loading = true;
                          _emailError = null;
                        });
                        try {
                          await AuthService().signInWithEmailPassword(
                            _emailCtrl.text.trim(),
                            _passCtrl.text.trim(),
                          );
                          await _claimPendingPostIfNeeded(priorAnonUid);
                          if (mounted) Navigator.pop(context);
                          if (parentCtx.mounted) {
                            ScaffoldMessenger.of(parentCtx).showSnackBar(
                              const SnackBar(content: Text('Signed in successfully!')),
                            );
                          }
                        } catch (_) {
                          if (mounted) {
                            setState(() {
                              _loading = false;
                              _emailError = 'Incorrect email or password.';
                            });
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF141F35),
                  foregroundColor: const Color(0xFF00E5FF),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00E5FF)),
                      )
                    : const Text(
                        'Sign in with email',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                final parentCtx = widget.parentContext;
                _adminTapCount++;
                HapticFeedback.lightImpact();
                if (_adminTapCount >= 5) {
                  _adminTapCount = 0;
                  final user = AuthService().currentUser;
                  if (user != null) {
                    final doc = await FirebaseFirestore.instance
                        .collection('users')
                        .doc(user.uid)
                        .get();
                    if (doc.exists && doc.data()?['role'] == 'admin') {
                      if (mounted) Navigator.pop(context);
                      if (parentCtx.mounted) {
                        Navigator.push(
                          parentCtx,
                          MaterialPageRoute(builder: (_) => const AdminDashboardScreen()),
                        );
                      }
                    }
                  }
                }
              },
              child: const Padding(
                padding: EdgeInsets.only(top: 14, bottom: 4),
                child: Text('v1.1.0', style: TextStyle(color: Color(0xFF252D3F), fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
