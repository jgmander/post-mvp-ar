import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({Key? key}) : super(key: key);

  Future<bool> _isAdmin() async {
    final user = AuthService().currentUser;
    if (user == null) return false;
    
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if (doc.exists) {
        return doc.data()?['role'] == 'admin';
      }
    } catch (e) {
      debugPrint("Admin check failed: $e");
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _isAdmin(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0D1220),
            body: Center(child: CircularProgressIndicator(color: Color(0xFF4F8EF7))),
          );
        }

        if (snapshot.hasError || !snapshot.hasData || snapshot.data != true) {
          return Scaffold(
            backgroundColor: const Color(0xFF0D1220),
            appBar: AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              iconTheme: const IconThemeData(color: Colors.white),
            ),
            body: const Center(
              child: Text(
                'Permission Denied',
                style: TextStyle(color: Colors.redAccent, fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),
          );
        }

        return DefaultTabController(
          length: 2,
          child: Scaffold(
            backgroundColor: const Color(0xFF0D1220),
            appBar: AppBar(
              backgroundColor: const Color(0xFF161B25),
              iconTheme: const IconThemeData(color: Colors.white),
              title: const Text('Admin Console', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              bottom: const TabBar(
                indicatorColor: Color(0xFF4F8EF7),
                labelColor: Colors.white,
                unselectedLabelColor: Color(0xFF8896B0),
                tabs: [
                  Tab(text: 'Users'),
                  Tab(text: 'Flagged Posts'),
                ],
              ),
            ),
            body: const TabBarView(
              children: [
                Center(child: Text('No users found', style: TextStyle(color: Color(0xFF8896B0)))),
                Center(child: Text('No flagged posts', style: TextStyle(color: Color(0xFF8896B0)))),
              ],
            ),
          ),
        );
      },
    );
  }
}
