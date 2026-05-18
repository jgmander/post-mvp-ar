import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
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

  // Collision Resolution Cache
  OAuthCredential? _pendingAppleCredential;

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
          
          if (_pendingAppleCredential != null) {
            try {
              await _auth.currentUser!.linkWithCredential(_pendingAppleCredential!);
              print("Successfully fused pending Apple credential to Google session");
            } catch (fusionError) {
              print("Failed to fuse pending credential: $fusionError");
            } finally {
              _pendingAppleCredential = null;
            }
          }
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use') {
            print("Credential already in use, pivoting to standard sign-in");
            await _auth.signInWithCredential(credential);
            
            if (_pendingAppleCredential != null) {
              try {
                await _auth.currentUser!.linkWithCredential(_pendingAppleCredential!);
                print("Successfully fused pending Apple credential to Google session");
              } catch (fusionError) {
                print("Failed to fuse pending credential: $fusionError");
              } finally {
                _pendingAppleCredential = null;
              }
            }
            return;
          } else if (e.code == 'provider-already-linked') {
            print("Google provider already linked to this session. Proceeding.");
            // Treat as success — user is already authenticated with this provider.
          } else if (e.code == 'account-exists-with-different-credential' || e.code == 'email-already-in-use') {
            print("Email collision: ${e.code}");
            throw Exception("An account already exists with the same email address but different sign-in credentials. Please sign in using a provider associated with this email address.");
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

  String _generateNonce([int length = 32]) {
    const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
  }

  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  Future<void> signInWithApple() async {
    try {
      final rawNonce = _generateNonce();
      final hashedNonce = _sha256ofString(rawNonce);

      final appleIdCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );

      final OAuthCredential credential = OAuthProvider('apple.com').credential(
        idToken: appleIdCredential.identityToken,
        rawNonce: rawNonce,
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
            return;
          } else if (e.code == 'provider-already-linked') {
            print("Apple provider already linked to this session. Proceeding.");
            // Treat as success — user is already authenticated with this provider.
          } else if (e.code == 'account-exists-with-different-credential' || e.code == 'email-already-in-use') {
            print("Email collision detected. Caching Apple credential and rethrowing for UI interception.");
            _pendingAppleCredential = credential;
            rethrow;
          } else {
            rethrow;
          }
        }
        
        final Map<String, dynamic> userData = {
          'uid': _auth.currentUser!.uid,
          'role': 'user',
          'tier': 'free',
          'createdAt': FieldValue.serverTimestamp(),
        };
        if (appleIdCredential.email != null) {
          userData['email'] = appleIdCredential.email;
        }
        
        await FirebaseFirestore.instance.collection('users').doc(_auth.currentUser!.uid).set(
          userData, 
          SetOptions(merge: true)
        );
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
    _pendingAppleCredential = null;
    await signInAnonymously();
  }

  Future<List<String>> getProvidersForEmail(String email) async {
    return await _auth.fetchSignInMethodsForEmail(email);
  }
}
