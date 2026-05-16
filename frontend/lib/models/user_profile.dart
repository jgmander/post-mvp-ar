class UserProfile {
  final String uid;
  final String email;
  final String role;
  final String tier;

  UserProfile({
    required this.uid,
    required this.email,
    this.role = 'user',
    this.tier = 'free',
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      uid: json['uid'] ?? '',
      email: json['email'] ?? '',
      role: json['role'] ?? 'user',
      tier: json['tier'] ?? 'free',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'uid': uid,
      'email': email,
      'role': role,
      'tier': tier,
    };
  }
}
