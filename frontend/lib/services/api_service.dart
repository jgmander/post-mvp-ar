import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/post.dart';

class ApiService {
  // Replace with actual deployed Cloud Run URL when available.
  // For Local testing via Android Emulator, use 10.0.2.2.
  static const String baseUrl = 'http://10.0.2.2:8080';

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
