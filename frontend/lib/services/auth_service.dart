import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Value-Gated Progressive Profiling: Local Session State
  bool hasDroppedFreePost = false;

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
    if (_auth.currentUser != null) {
      await FirebaseFirestore.instance.collection('users').doc(_auth.currentUser!.uid).set({
        'uid': _auth.currentUser!.uid,
        'email': email,
        'role': 'user',
        'tier': 'free',
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      print("User profile generated in Firestore");
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }
}
