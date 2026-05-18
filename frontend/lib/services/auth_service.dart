import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
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
  bool _isGoogleSignInInitialized = false;

  Future<void> linkWithGoogle() async {
    final GoogleSignIn googleSignIn = GoogleSignIn.instance;
    if (!_isGoogleSignInInitialized) {
      await googleSignIn.initialize();
      _isGoogleSignInInitialized = true;
    }

    try {
      final GoogleSignInAccount? googleUser = await googleSignIn.authenticate();
      if (googleUser == null) return; // User canceled
      
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final OAuthCredential credential = GoogleAuthProvider.credential(
        accessToken: null, // Removed in google_sign_in 7.x
        idToken: googleAuth.idToken,
      );

      if (_auth.currentUser != null) {
        try {
          await _auth.currentUser!.linkWithCredential(credential);
          print("Successfully linked anonymous account with Google");
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use') {
            print("Credential already in use, pivoting to standard sign-in");
            await _auth.signInWithCredential(credential);
          } else {
            rethrow;
          }
        }
        
        await FirebaseFirestore.instance.collection('users').doc(_auth.currentUser!.uid).set({
          'uid': _auth.currentUser!.uid,
          'email': googleUser.email,
          'role': 'user',
          'tier': 'free',
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      print("Error linking with Google: $e");
      rethrow;
    }
  }

  Future<void> signInWithApple() async {
    try {
      final appleIdCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      final OAuthCredential credential = OAuthProvider('apple.com').credential(
        idToken: appleIdCredential.identityToken,
        accessToken: appleIdCredential.authorizationCode,
      );

      if (_auth.currentUser != null) {
        try {
          await _auth.currentUser!.linkWithCredential(credential);
          print("Successfully linked anonymous account with Apple");
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use') {
            print("Credential already in use, pivoting to standard sign-in");
            await _auth.signInWithCredential(credential);
          } else {
            rethrow;
          }
        }
        
        await FirebaseFirestore.instance.collection('users').doc(_auth.currentUser!.uid).set({
          'uid': _auth.currentUser!.uid,
          'email': appleIdCredential.email ?? 'apple_hidden',
          'role': 'user',
          'tier': 'free',
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      print("Error signing in with Apple: $e");
      rethrow;
    }
  }

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
    await signInAnonymously();
  }
}
