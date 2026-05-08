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
  final ValueNotifier<String> trackingState = ValueNotifier<String>('INITIALIZING');

  @override
  void initState() {
    super.initState();
    platform.invokeMethod('startArSession').then((_) {
      _triggerNativeARAnchor();
    });
    _setupMethodChannelHandler();
  }

  void _setupMethodChannelHandler() {
    platform.setMethodCallHandler((call) async {
      if (call.method == "onTrackingStateChanged") {
        String state = call.arguments.toString();
        trackingState.value = state;
        print("Flutter tracking state updated: \$state");
      }
    });
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
        'body': "Hi, I'm standing at your post and I'd like to connect.",
      },
    );
    if (await canLaunchUrl(smsUri)) {
      await launchUrl(smsUri);
    } else {
      print('Could not launch SMS');
    }
  }

  @override
  void dispose() {
    platform.invokeMethod('stopArSession');
    trackingState.dispose();
    super.dispose();
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
          ValueListenableBuilder<String>(
            valueListenable: trackingState,
            builder: (context, state, child) {
              if (state == 'LOCALIZING' || state == 'INITIALIZING') {
                return Center(
                  child: Container(
                    padding: EdgeInsets.all(24),
                    margin: EdgeInsets.symmetric(horizontal: 32),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Colors.white),
                        SizedBox(height: 16),
                        Text(
                          'Point your camera at surrounding buildings to localize...',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                  ),
                );
              } else if (state == 'TRACKING') {
                return Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: Container(
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.white),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Location Found. Anchoring Post Data.',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return Container(); // Fallback for UNKNOWN
            },
          ),
        ],
      ),
      bottomSheet: ValueListenableBuilder<String>(
        valueListenable: trackingState,
        builder: (context, state, child) {
          if (state == 'TRACKING') {
            return Container(
              color: Colors.white,
              padding: EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.propertyData['price'] ?? 'Unknown Caption',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text(
                    "Dropped by: Spatial Community",
                    style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                  ),
                  SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _textAgent,
                    style: ElevatedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue,
                    ),
                    child: Text('Reply to Post', style: TextStyle(fontSize: 18, color: Colors.white)),
                  ),
                ],
              ),
            );
          }
          return SizedBox.shrink(); // Hidden while localizing
        },
      ),
    );
  }
}
