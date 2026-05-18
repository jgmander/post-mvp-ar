import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';

class _CollisionColors {
  static const surface    = Color(0xFF161B25);
  static const textPrimary   = Color(0xFFF0F4FF);
  static const textSecondary = Color(0xFF8896B0);
  static const divider    = Color(0xFF252D3F);
}

class AuthCollisionBottomSheet extends StatelessWidget {
  final String email;
  final List<String> availableProviders;

  const AuthCollisionBottomSheet({
    super.key,
    required this.email,
    required this.availableProviders,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _CollisionColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
        left: 24,
        right: 24,
        top: 14,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              margin: const EdgeInsets.only(bottom: 24),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: _CollisionColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Icon(
            Icons.lock_person_rounded,
            color: Colors.white,
            size: 48,
          ),
          const SizedBox(height: 20),
          const Text(
            'Account Exists',
            style: TextStyle(
              color: _CollisionColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            "Welcome back! It looks like you've been here before. To keep your account secure, please verify it's you using your original sign-in method.",
            style: const TextStyle(
              color: _CollisionColors.textSecondary,
              fontSize: 15,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _CollisionColors.divider),
            ),
            child: Text(
              email,
              style: const TextStyle(
                color: _CollisionColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 32),
          if (availableProviders.contains('google.com'))
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: () async {
                  HapticFeedback.mediumImpact();
                  try {
                    await AuthService().linkWithGoogle();
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Accounts successfully merged!')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to link Google: ${e.toString()}')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.g_mobiledata_rounded, color: _CollisionColors.surface, size: 32),
                label: const Text('Continue with Google', style: TextStyle(color: _CollisionColors.surface, fontSize: 16, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _CollisionColors.textPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          if (availableProviders.contains('apple.com')) ...[
            if (availableProviders.contains('google.com')) const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton.icon(
                onPressed: () async {
                  HapticFeedback.mediumImpact();
                  try {
                    await AuthService().signInWithApple();
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Accounts successfully merged!')),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to link Apple: ${e.toString()}')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.apple_rounded, color: Colors.white, size: 28),
                label: const Text('Continue with Apple', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: Colors.white24, width: 1),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
