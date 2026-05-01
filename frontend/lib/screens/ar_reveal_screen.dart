import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class ArRevealScreen extends StatefulWidget {
  final Map<String, dynamic> propertyData;

  ArRevealScreen({required this.propertyData});

  @override
  _ArRevealScreenState createState() => _ArRevealScreenState();
}

class _ArRevealScreenState extends State<ArRevealScreen> {
  static const platform = MethodChannel('com.postspatial.ar/geospatial');

  @override
  void initState() {
    super.initState();
    _triggerNativeARAnchor();
  }

  Future<void> _triggerNativeARAnchor() async {
    try {
      double lat = widget.propertyData['lat'] ?? 0.0;
      double lng = widget.propertyData['lng'] ?? 0.0;
      String assetPath = Platform.isIOS ? 'assets/models/For_Sale_Sign.usdz' : 'assets/models/for_sale_sign.glb';
      
      await platform.invokeMethod('anchorModel', {
        'lat': lat,
        'lng': lng,
        'assetPath': assetPath,
      });
    } on PlatformException catch (e) {
      print("Failed to invoke anchorModel: '\${e.message}'.");
    }
  }

  Future<void> _textAgent() async {
    final String phone = widget.propertyData['phone'] ?? '';
    final Uri smsUri = Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: <String, String>{
        'body': "Hi, I'm standing outside the property and I'd like to schedule a tour.",
      },
    );
    if (await canLaunchUrl(smsUri)) {
      await launchUrl(smsUri);
    } else {
      print('Could not launch SMS');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // AR view will be underneath natively
      appBar: AppBar(
        title: Text('AR Reveal', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black45,
        elevation: 0,
        iconTheme: IconThemeData(color: Colors.white),
      ),
      body: Stack(
        children: [
          // The native camera stream handles rendering the AR under the transparent scaffold
          Center(
            child: Text(
              'AR Environment Initializing...',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
      bottomSheet: Container(
        color: Colors.white,
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.propertyData['price'] ?? 'Unknown Price',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 8),
            Text(
              '\${widget.propertyData['beds'] ?? 0} Beds, \${widget.propertyData['baths'] ?? 0} Baths',
              style: TextStyle(fontSize: 18, color: Colors.grey[700]),
            ),
            SizedBox(height: 24),
            ElevatedButton(
              onPressed: _textAgent,
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: 16),
                backgroundColor: Colors.blue,
              ),
              child: Text('Text the Agent', style: TextStyle(fontSize: 18, color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
