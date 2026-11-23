import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import '../models/post.dart';

class ApiService {
  // Cloud Run Production URL
  static const String baseUrl = 'https://post-mvp-backend-clb6khb3uq-uc.a.run.app';

  // Singleton pattern — prevents multiple redundant health check pings on boot.
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal() {
    _healthCheck();
  }

  Future<void> _healthCheck() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/'));
      if (response.statusCode == 200) {
        print('Backend Health Check: SUCCESS - Connected to $baseUrl');
      } else {
        print('Backend Health Check: WARNING - Received status ${response.statusCode}');
      }
    } catch (e) {
      print('Backend Health Check: ERROR - Could not connect to $baseUrl. Details: $e');
    }
  }

  Future<Post> createPost(Post post) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('Not authenticated');
    final idToken = await user.getIdToken();

    final response = await http.post(
      Uri.parse('$baseUrl/posts'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode(post.toJson()),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return Post.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to create post: ${response.body}');
    }
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

      final response = await http.patch(
        Uri.parse('$baseUrl/posts/$postId'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) {
        return Post.fromJson(jsonDecode(response.body));
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
      await http.post(Uri.parse('$baseUrl/posts/$postId/view'));
    } catch (_) {}
  }

  /// Reports a post via the Cloud Run backend so Gemini 2.5 Flash can
  /// re-screen and auto-remove confirmed policy violations immediately.
  Future<bool> reportPost(String postId) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return false;
      final idToken = await user.getIdToken();
      final response = await http.post(
        Uri.parse('$baseUrl/posts/$postId/report'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
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
      final response = await http.delete(
        Uri.parse('$baseUrl/posts/$postId'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
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
      final response = await http.delete(
        Uri.parse('$baseUrl/users/me/posts'),
        headers: {
          'Authorization': 'Bearer $idToken',
          'Content-Type': 'application/json',
        },
      );
      return response.statusCode == 200;
    } catch (e) {
      print('Failed to delete user posts: $e');
      return false;
    }
  }

  Future<List<Post>> getNearbyPosts(double lat, double lng, {double radiusKm = 1.0}) async {
    final response = await http.get(
      Uri.parse('$baseUrl/posts?lat=$lat&lng=$lng&radius_km=$radiusKm'),
    );

    if (response.statusCode == 200) {
      Iterable l = jsonDecode(response.body);
      return List<Post>.from(l.map((model) => Post.fromJson(model)));
    } else {
      throw Exception('Failed to load posts');
    }
  }

  Future<Map<String, String>?> getPlaceFromCoordinates(double lat, double lng) async {
    const mapsApiKey = String.fromEnvironment('MAPS_API_KEY');

    if (mapsApiKey.isEmpty) {
      print('WARNING: MAPS_API_KEY not found in dart-define environment.');
      return null;
    }

    try {
      final placesUrl = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=$lat,$lng&radius=35&key=$mapsApiKey';
      final placesResponse = await http.get(Uri.parse(placesUrl));
      if (placesResponse.statusCode == 200) {
        final data = jsonDecode(placesResponse.body);
        if (data['results'] != null && data['results'].isNotEmpty) {
          final firstResult = data['results'][0];
          String name = firstResult['name'] ?? 'Unknown Place';
          String category = 'Unknown';
          if (firstResult['types'] != null && (firstResult['types'] as List).isNotEmpty) {
            category = firstResult['types'][0].toString().replaceAll('_', ' ');
          }
          return {'name': name, 'category': category};
        }
      }

      final geocodeUrl = 'https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$mapsApiKey';
      final geocodeResponse = await http.get(Uri.parse(geocodeUrl));
      if (geocodeResponse.statusCode == 200) {
        final data = jsonDecode(geocodeResponse.body);
        if (data['results'] != null && data['results'].isNotEmpty) {
          final firstResult = data['results'][0];
          String address = firstResult['formatted_address'] ?? 'Unknown Address';
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
    List<String> placeIds = [];
    if (mapsApiKey.isEmpty) return placeIds;
    try {
      final placesUrl = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=$lat,$lng&radius=50&type=building&key=$mapsApiKey';
      final response = await http.get(Uri.parse(placesUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['results'] != null) {
          for (var result in data['results']) {
            if (result['place_id'] != null) {
              placeIds.add(result['place_id']);
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
