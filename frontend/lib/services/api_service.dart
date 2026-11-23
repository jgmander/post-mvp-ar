import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/post.dart';

class PostApiException implements Exception {
  final String message;
  final int? statusCode;
  final bool isNetworkError;

  const PostApiException(
    this.message, {
    this.statusCode,
    this.isNetworkError = false,
  });

  @override
  String toString() => message;
}

class _HttpReply {
  final int statusCode;
  final String body;
  const _HttpReply(this.statusCode, this.body);
}

class ApiService {
  // Cloud Run Production URL
  static const String baseUrl = 'https://post-mvp-backend-clb6khb3uq-uc.a.run.app';
  static const MethodChannel _nativeHttpChannel =
      MethodChannel('com.postspatial.net/http');
  static final Random _rng = Random();

  // Singleton pattern — prevents multiple redundant health check pings on boot.
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() {
    _healthCheck();
  }

  static String generateClientPostId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rand = _rng.nextInt(899999) + 100000;
    return 'p_${ts}_$rand';
  }

  /// Sends an HTTP request using native iOS URLSession (with Wi-Fi Assist / 5G failover)
  /// on iPhones, and a fresh bounded-timeout socket client on Android/tests so stale
  /// fringe Wi-Fi sockets never hang or cause sticky ClientException loops.
  Future<_HttpReply> _sendRequest(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    String? body,
    Duration timeout = const Duration(milliseconds: 8500),
  }) async {
    if (!kIsWeb && Platform.isIOS) {
      try {
        final raw = await _nativeHttpChannel
            .invokeMethod<Map<dynamic, dynamic>>('request', {
          'method': method,
          'url': uri.toString(),
          'headers': headers,
          'body': body,
          'timeoutMs': timeout.inMilliseconds,
        }).timeout(timeout + const Duration(seconds: 2));

        if (raw != null) {
          final code = (raw['statusCode'] as num?)?.toInt() ?? 0;
          final respBody = (raw['body'] as String?) ?? '';
          return _HttpReply(code, respBody);
        }
      } on MissingPluginException {
        // Unit test / fallback environment: proceed to IOClient below.
      } on PlatformException catch (e) {
        throw PostApiException(
          e.message ?? 'Network connection interrupted.',
          isNetworkError: true,
        );
      } on TimeoutException {
        throw const PostApiException(
          'Request timed out on weak signal.',
          isNetworkError: true,
        );
      }
    }

    final rawClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 3);
    final client = IOClient(rawClient);
    try {
      final request = http.Request(method, uri);
      if (headers != null) {
        request.headers.addAll(headers);
      }
      if (body != null) {
        request.body = body;
      }
      final streamed = await client.send(request).timeout(timeout);
      final respBody = await streamed.stream.bytesToString().timeout(timeout);
      return _HttpReply(streamed.statusCode, respBody);
    } on TimeoutException {
      throw const PostApiException(
        'Request timed out on weak signal.',
        isNetworkError: true,
      );
    } on SocketException {
      throw const PostApiException(
        'Network signal interrupted.',
        isNetworkError: true,
      );
    } on http.ClientException {
      throw const PostApiException(
        'Connection interrupted while switching networks.',
        isNetworkError: true,
      );
    } finally {
      client.close();
    }
  }

  Future<void> _healthCheck() async {
    try {
      final response = await _sendRequest(
        'GET',
        Uri.parse('$baseUrl/'),
        timeout: const Duration(seconds: 5),
      );
      if (response.statusCode == 200) {
        print('Backend Health Check: SUCCESS - Connected to $baseUrl');
      } else {
        print('Backend Health Check: WARNING - Received status ${response.statusCode}');
      }
    } catch (e) {
      print('Backend Health Check: ERROR - Could not connect to $baseUrl. Details: $e');
    }
  }

  /// Creates a post with automatic idempotent retry (`client_post_id`) so weak
  /// Wi-Fi-to-cellular transitions neither drop the post nor create duplicates.
  Future<Post> createPost(Post post, {String? clientPostId}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const PostApiException('Please sign in or allow guest session to post.');
    }
    final idToken = await user.getIdToken();
    final effectiveClientId = (clientPostId != null && clientPostId.isNotEmpty)
        ? clientPostId
        : (post.id != null && post.id!.isNotEmpty)
            ? post.id!
            : generateClientPostId();

    final payload = <String, dynamic>{
      ...post.toJson(),
      'client_post_id': effectiveClientId,
    };
    final encodedBody = jsonEncode(payload);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $idToken',
    };

    Object? lastError;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await _sendRequest(
          'POST',
          Uri.parse('$baseUrl/posts'),
          headers: headers,
          body: encodedBody,
          timeout: const Duration(seconds: 8),
        );

        if (response.statusCode == 200 || response.statusCode == 201) {
          return Post.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
        }

        String detail = 'Server returned ${response.statusCode}';
        try {
          final parsed = jsonDecode(response.body);
          if (parsed is Map && parsed['detail'] != null) {
            detail = parsed['detail'].toString();
          }
        } catch (_) {}

        if (response.statusCode >= 400 && response.statusCode < 500) {
          throw PostApiException(detail, statusCode: response.statusCode);
        }
        lastError = PostApiException(
          detail,
          statusCode: response.statusCode,
          isNetworkError: true,
        );
      } on PostApiException catch (e) {
        if (!e.isNetworkError) rethrow;
        lastError = e;
      } catch (e) {
        lastError = e;
      }

      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 550));
      }
    }

    if (lastError is PostApiException) {
      throw PostApiException(
        'Connection spotty right now (${lastError.message}). Tap Post again in a moment.',
        isNetworkError: true,
      );
    }
    throw const PostApiException(
      'Connection spotty right now. Tap Post again in a moment.',
      isNetworkError: true,
    );
  }

  /// Updates caption, permanence/TTL, or claims an anonymous post after sign-in.
  Future<Post?> updatePost(
    String postId, {
    String? caption,
    bool? isPermanent,
    DateTime? expiresAt,
    String? actionUrl,
    String? claimFromUid,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;
      final idToken = await user.getIdToken();

      final payload = <String, dynamic>{
        if (caption != null) 'caption': caption,
        if (isPermanent != null) 'is_permanent': isPermanent,
        if (expiresAt != null) 'expires_at': expiresAt.toUtc().toIso8601String(),
        if (actionUrl != null) 'action_url': actionUrl,
        if (claimFromUid != null) 'claim_from_uid': claimFromUid,
      };

      final response = await _sendRequest(
        'PATCH',
        Uri.parse('$baseUrl/posts/$postId'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
        timeout: const Duration(seconds: 8),
      );
      if (response.statusCode == 200) {
        return Post.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
      }
      print('Failed to update post $postId (${response.statusCode}): ${response.body}');
      return null;
    } catch (e) {
      print('Error updating post $postId: $e');
      return null;
    }
  }

  /// Increments post view count on tap.
  Future<void> viewPost(String postId) async {
    if (postId.isEmpty) return;
    try {
      await _sendRequest(
        'POST',
        Uri.parse('$baseUrl/posts/$postId/view'),
        timeout: const Duration(seconds: 4),
      );
    } catch (_) {}
  }

  /// Reports a post via the Cloud Run backend.
  Future<bool> reportPost(String postId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final idToken = await user.getIdToken();
      final response = await _sendRequest(
        'POST',
        Uri.parse('$baseUrl/posts/$postId/report'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
        timeout: const Duration(seconds: 7),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Backend reportPost fallback triggered: $e');
      return false;
    }
  }

  /// Deletes a post via the authenticated backend endpoint.
  Future<bool> deletePost(String postId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final idToken = await user.getIdToken();
      final response = await _sendRequest(
        'DELETE',
        Uri.parse('$baseUrl/posts/$postId'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
        timeout: const Duration(seconds: 7),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Failed to delete post $postId: $e');
      return false;
    }
  }

  /// Deletes all posts owned by the caller via the backend Admin SDK.
  Future<bool> deleteMyPosts() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final idToken = await user.getIdToken();
      final response = await _sendRequest(
        'DELETE',
        Uri.parse('$baseUrl/users/me/posts'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
        timeout: const Duration(seconds: 10),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Failed to delete user posts: $e');
      return false;
    }
  }

  Future<List<Post>> getNearbyPosts(double lat, double lng, {double radiusKm = 1.0}) async {
    final response = await _sendRequest(
      'GET',
      Uri.parse('$baseUrl/posts?lat=$lat&lng=$lng&radius_km=$radiusKm'),
      timeout: const Duration(seconds: 7),
    );

    if (response.statusCode == 200) {
      final Iterable l = jsonDecode(response.body) as Iterable;
      return List<Post>.from(
        l.map((model) => Post.fromJson(model as Map<String, dynamic>)),
      );
    } else {
      throw PostApiException('Failed to load posts (${response.statusCode})');
    }
  }

  Future<Map<String, String>?> getPlaceFromCoordinates(double lat, double lng) async {
    const mapsApiKey = String.fromEnvironment('MAPS_API_KEY');

    if (mapsApiKey.isEmpty) {
      print('WARNING: MAPS_API_KEY not found in dart-define environment.');
      return null;
    }

    try {
      final placesUrl =
          'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=$lat,$lng&radius=35&key=$mapsApiKey';
      final placesResponse = await _sendRequest(
        'GET',
        Uri.parse(placesUrl),
        timeout: const Duration(seconds: 5),
      );
      if (placesResponse.statusCode == 200) {
        final data = jsonDecode(placesResponse.body);
        if (data['results'] != null && (data['results'] as List).isNotEmpty) {
          final firstResult = data['results'][0];
          final String name = firstResult['name'] ?? 'Unknown Place';
          String category = 'Unknown';
          if (firstResult['types'] != null && (firstResult['types'] as List).isNotEmpty) {
            category = firstResult['types'][0].toString().replaceAll('_', ' ');
          }
          return {'name': name, 'category': category};
        }
      }

      final geocodeUrl =
          'https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$mapsApiKey';
      final geocodeResponse = await _sendRequest(
        'GET',
        Uri.parse(geocodeUrl),
        timeout: const Duration(seconds: 5),
      );
      if (geocodeResponse.statusCode == 200) {
        final data = jsonDecode(geocodeResponse.body);
        if (data['results'] != null && (data['results'] as List).isNotEmpty) {
          final firstResult = data['results'][0];
          final String address = firstResult['formatted_address'] ?? 'Unknown Address';
          String category = 'address';
          if (firstResult['types'] != null && (firstResult['types'] as List).isNotEmpty) {
            category = firstResult['types'][0].toString().replaceAll('_', ' ');
          }
          return {'name': address, 'category': category};
        }
      }
    } catch (e) {
      print('Failed to resolve coordinates: $e');
    }
    return null;
  }

  Future<List<String>> getNearbyBuildings(double lat, double lng) async {
    const mapsApiKey = String.fromEnvironment('MAPS_API_KEY');
    final List<String> placeIds = [];
    if (mapsApiKey.isEmpty) return placeIds;
    try {
      final placesUrl =
          'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=$lat,$lng&radius=50&type=building&key=$mapsApiKey';
      final response = await _sendRequest(
        'GET',
        Uri.parse(placesUrl),
        timeout: const Duration(seconds: 5),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['results'] != null) {
          for (final result in data['results']) {
            if (result['place_id'] != null) {
              placeIds.add(result['place_id'] as String);
            }
          }
        }
      }
    } catch (e) {
      print('Error fetching nearby buildings: $e');
    }
    return placeIds;
  }
}
