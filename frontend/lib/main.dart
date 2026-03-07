import 'package:flutter/material.dart';
import 'ui/progressive_view.dart';

void main() {
  runApp(PostApp());
}

class PostApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Post AR MVP',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: ProgressiveView(),
    );
  }
}
