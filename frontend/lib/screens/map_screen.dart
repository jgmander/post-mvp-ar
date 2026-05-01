import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'ar_reveal_screen.dart';

class MapScreen extends StatefulWidget {
  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  GoogleMapController? _mapController;
  final LatLng _initialPosition = LatLng(40.7251, -73.7055);
  Set<Marker> _markers = {};

  @override
  void initState() {
    super.initState();
    _listenToPosts();
  }

  void _listenToPosts() {
    FirebaseFirestore.instance.collection('posts').snapshots().listen((snapshot) {
      Set<Marker> newMarkers = {};
      for (var doc in snapshot.docs) {
        var data = doc.data();
        double lat = data['lat'] ?? 0.0;
        double lng = data['lng'] ?? 0.0;
        
        newMarkers.add(
          Marker(
            markerId: MarkerId(doc.id),
            position: LatLng(lat, lng),
            infoWindow: InfoWindow(
              title: data['price'] ?? 'Unknown Price',
              snippet: '${data['beds'] ?? 0} Beds, ${data['baths'] ?? 0} Baths',
            ),
            icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueViolet),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ArRevealScreen(propertyData: data),
                ),
              );
            },
          ),
        );
      }
      setState(() {
        _markers = newMarkers;
      });
    });
  }

  void _showCreatorBottomSheet() {
    final priceController = TextEditingController();
    final bedsController = TextEditingController();
    final bathsController = TextEditingController();
    final phoneController = TextEditingController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
            left: 16, right: 16, top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Create Property Post', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              TextField(controller: priceController, decoration: InputDecoration(labelText: 'Price (e.g. \$1.2M)')),
              TextField(controller: bedsController, decoration: InputDecoration(labelText: 'Beds'), keyboardType: TextInputType.number),
              TextField(controller: bathsController, decoration: InputDecoration(labelText: 'Baths'), keyboardType: TextInputType.number),
              TextField(controller: phoneController, decoration: InputDecoration(labelText: 'Agent Phone')),
              SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  if (_mapController == null) return;
                  
                  // Get center coordinates for the pin
                  LatLngBounds visibleRegion = await _mapController!.getVisibleRegion();
                  LatLng centerLatLng = LatLng(
                    (visibleRegion.northeast.latitude + visibleRegion.southwest.latitude) / 2,
                    (visibleRegion.northeast.longitude + visibleRegion.southwest.longitude) / 2,
                  );

                  await FirebaseFirestore.instance.collection('posts').add({
                    'lat': centerLatLng.latitude,
                    'lng': centerLatLng.longitude,
                    'price': priceController.text,
                    'beds': int.tryParse(bedsController.text) ?? 0,
                    'baths': int.tryParse(bathsController.text) ?? 0,
                    'phone': phoneController.text,
                    'timestamp': FieldValue.serverTimestamp(),
                  });

                  Navigator.pop(context);
                },
                child: Text('Drop Pin at Center'),
              ),
              SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _initialPosition, zoom: 16),
            markers: _markers,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onMapCreated: (controller) => _mapController = controller,
          ),
          Center(
            child: Icon(Icons.location_on, size: 40, color: Colors.blue.withOpacity(0.5)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreatorBottomSheet,
        child: Icon(Icons.add),
      ),
    );
  }
}
