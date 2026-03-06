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
}
