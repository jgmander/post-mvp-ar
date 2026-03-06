import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../models/post.dart';
import '../services/api_service.dart';

class CreatePostView extends StatefulWidget {
  @override
  _CreatePostViewState createState() => _CreatePostViewState();
}

class _CreatePostViewState extends State<CreatePostView> {
  final _contentController = TextEditingController();
  final _apiService = ApiService();
  String _visibilityType = '1-to-many';
  bool _isLoading = false;

  Future<void> _submitPost() async {
    if (_contentController.text.isEmpty) return;
    setState(() => _isLoading = true);

    try {
      Position position = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      
      final newPost = Post(
        latitude: position.latitude,
        longitude: position.longitude,
        altitude: position.altitude,
        messageContent: _contentController.text,
        creatorId: 'user_123', // Hardcoded for MVP
        visibilityType: _visibilityType,
        reach: 50, // Default 50m reach for MVP
      );

      final created = await _apiService.createPost(newPost);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Post Created! CTA: ${created.ctaText ?? 'None'}')),
      );
      Navigator.pop(context);
    } catch (e) {
       ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Create Digital Imprint')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _contentController,
              decoration: InputDecoration(
                labelText: 'Message Content',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _visibilityType,
              items: ['1-to-1', '1-to-many'].map((String value) {
                return DropdownMenuItem<String>(
                  value: value,
                  child: Text(value),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) setState(() => _visibilityType = val);
              },
              decoration: InputDecoration(
                labelText: 'Visibility',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 24),
            _isLoading 
              ? CircularProgressIndicator()
              : ElevatedButton(
                  onPressed: _submitPost,
                  child: Text('Drop Post Here'),
                  style: ElevatedButton.styleFrom(minimumSize: Size.fromHeight(50)),
                )
          ],
        ),
      ),
    );
  }
}
