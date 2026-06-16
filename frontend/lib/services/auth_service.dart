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
  OAuthCredential? _pendingGoogleCredential;
  String? lastCollisionEmail;
  String? lastCollidedProvider;

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
      final GoogleSignInAccount googleUser = await googleSignIn.authenticate(); // User canceled
      
      final GoogleSignInAuthentication googleAuth = googleUser.authentication;
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
            return;
          } else if (e.code == 'provider-already-linked') {
            print("Google provider already linked to this session. Proceeding.");
            // Treat as success — user is already authenticated with this provider.
          } else if (e.code == 'account-exists-with-different-credential' || e.code == 'email-already-in-use') {
            print("Email collision detected. Caching Google credential and rethrowing for UI interception.");
            _pendingGoogleCredential = credential;
            lastCollisionEmail = googleUser.email;
            lastCollidedProvider = 'google.com';
            rethrow;
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

  String _decodeEmailFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return '';
      final payload = parts[1];
      var normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = json.decode(decoded);
      return data['email'] ?? '';
    } catch (_) {
      return '';
    }
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
          
          if (_pendingGoogleCredential != null) {
            try {
              await _auth.currentUser!.linkWithCredential(_pendingGoogleCredential!);
              print("Successfully fused pending Google credential to Apple session");
            } catch (e) {
              print("Failed to fuse pending Google credential: $e");
            } finally {
              _pendingGoogleCredential = null;
            }
          }
        } on FirebaseAuthException catch (e) {
          if (e.code == 'credential-already-in-use') {
            print("Credential already in use, pivoting to standard sign-in");
            await _auth.signInWithCredential(credential);
            
            if (_pendingGoogleCredential != null) {
              try {
                await _auth.currentUser!.linkWithCredential(_pendingGoogleCredential!);
                print("Successfully fused pending Google credential to Apple session");
              } catch (e) {
                print("Failed to fuse pending Google credential: $e");
              } finally {
                _pendingGoogleCredential = null;
              }
            }
            return;
          } else if (e.code == 'provider-already-linked') {
            print("Apple provider already linked to this session. Proceeding.");
            // Treat as success — user is already authenticated with this provider.
          } else if (e.code == 'account-exists-with-different-credential' || e.code == 'email-already-in-use') {
            print("Email collision detected. Extracting JWT and rethrowing for UI interception.");
            
            String collisionEmail = appleIdCredential.email ?? '';
            if (collisionEmail.isEmpty && appleIdCredential.identityToken != null) {
              collisionEmail = _decodeEmailFromJwt(appleIdCredential.identityToken!);
            }
            lastCollisionEmail = collisionEmail;
            lastCollidedProvider = 'apple.com';
            
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

  /// Sign in (or link) with email + password.
  /// Used by the Play Store reviewer account and future email-auth users.
  Future<void> signInWithEmailPassword(String email, String password) async {
    final credential = EmailAuthProvider.credential(email: email, password: password);
    try {
      if (_auth.currentUser != null && _auth.currentUser!.isAnonymous) {
        // Promote anonymous session → named account
        await _auth.currentUser!.linkWithCredential(credential);
        print('Linked anonymous session to email account: $email');
      } else {
        await _auth.signInWithEmailAndPassword(email: email, password: password);
        print('Signed in with email: $email');
      }
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .set({
        'uid': _auth.currentUser!.uid,
        'email': email,
        'role': 'user',
        'tier': 'free',
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseAuthException catch (e) {
      if (e.code == 'credential-already-in-use' || e.code == 'email-already-in-use') {
        // Email already has an account — just sign in directly
        await _auth.signInWithEmailAndPassword(email: email, password: password);
      } else {
        rethrow;
      }
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
    _pendingGoogleCredential = null;
    await signInAnonymously();
  }

  Future<List<String>> getProvidersForEmail(String email) async {
    // fetchSignInMethodsForEmail was removed in firebase_auth 5.0 for security.
    // Since we only support Google and Apple, we use deductive routing.
    if (lastCollidedProvider == 'apple.com') return ['google.com'];
    if (lastCollidedProvider == 'google.com') return ['apple.com'];
    return ['google.com', 'apple.com'];
  }
}
