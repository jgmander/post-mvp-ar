import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';

class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

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
            body: TabBarView(
              children: [
                const Center(child: Text('No users found', style: TextStyle(color: Color(0xFF8896B0)))),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('posts').where('is_flagged', isEqualTo: true).snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator(color: Color(0xFF4F8EF7)));
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return const Center(child: Text('No flagged posts', style: TextStyle(color: Color(0xFF8896B0))));
                    }
                    final docs = snapshot.data!.docs;
                    return ListView.builder(
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final data = docs[index].data() as Map<String, dynamic>;
                        final caption = data['caption'] ?? 'No Caption';
                        return Card(
                          color: const Color(0xFF161B25),
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            title: Text(caption, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            subtitle: Text('Owner: ${data['owner_id'] ?? 'Unknown'}', style: const TextStyle(color: Color(0xFF8896B0), fontSize: 12)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.check_circle_outline_rounded, color: Colors.greenAccent),
                                  onPressed: () async {
                                    await docs[index].reference.update({'is_flagged': false});
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Post dismissed from moderation queue.')),
                                      );
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_rounded, color: Colors.redAccent),
                                  onPressed: () async {
                                    await docs[index].reference.delete();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Post permanently deleted.')),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
