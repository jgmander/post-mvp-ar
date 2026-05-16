import 'package:firebase_auth/firebase_auth.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<void> signInAnonymously() async {
    if (_auth.currentUser == null) {
      try {
        await _auth.signInAnonymously();
        print("Signed in anonymously: ${_auth.currentUser?.uid}");
      } catch (e) {
        print("Failed to sign in anonymously: $e");
      }
    }
  }

  // Placeholder for future email/oauth integration
  Future<void> upgradeWithEmail(String email, String password) async {
    // Scaffold for upgrade path
    print("Scaffold: Upgrade account with $email");
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }
}
