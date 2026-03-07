import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/post.dart';

class ApiService {
  // Cloud Run Production URL
  static const String baseUrl = 'https://post-mvp-backend-clb6khb3uq-uc.a.run.app';

  ApiService() {
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
    final response = await http.post(
      Uri.parse('$baseUrl/posts'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(post.toJson()),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return Post.fromJson(jsonDecode(response.body));
    } else {
      throw Exception('Failed to create post: ${response.body}');
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

  String? _cachedMapsApiKey;

  Future<Map<String, String>?> getPlaceFromCoordinates(double lat, double lng) async {
    if (_cachedMapsApiKey == null) {
      try {
        final configResponse = await http.get(Uri.parse('\$baseUrl/v1/auth/config'));
        if (configResponse.statusCode == 200) {
          final data = jsonDecode(configResponse.body);
          _cachedMapsApiKey = data['maps_api_key'];
        }
      } catch (e) {
        print("Network error fetching auth config: \$e");
      }
    }
    
    if (_cachedMapsApiKey == null || _cachedMapsApiKey!.isEmpty) {
        print("WARNING: MAPS_API_KEY could not be securely fetched from backend.");
        return null;
    }

    // First try Places API to get a specific business/poi name
    try {
      final placesUrl = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=\$lat,\$lng&radius=15&key=\$_cachedMapsApiKey';
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
      
      // Fallback to Reverse Geocoding for physical addresses
      final geocodeUrl = 'https://maps.googleapis.com/maps/api/geocode/json?latlng=\$lat,\$lng&key=\$_cachedMapsApiKey';
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
      print('Failed to resolve coordinates: \$e');
    }
    return null;
  }

  Future<List<String>> getNearbyBuildings(double lat, double lng) async {
    if (_cachedMapsApiKey == null) {
      await getPlaceFromCoordinates(lat, lng); // Ensure key is fetched
    }
    List<String> placeIds = [];
    try {
      final placesUrl = 'https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=\$lat,\$lng&radius=30&type=building&key=\$_cachedMapsApiKey';
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
      print("Error fetching nearby buildings: \$e");
    }
    return placeIds;
  }
}
