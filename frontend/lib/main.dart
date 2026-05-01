import 'package:flutter/material.dart';
import 'screens/map_screen.dart';

void main() {
  runApp(PostApp());
}

class PostApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Post',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: MapScreen(),
    );
  }
}
