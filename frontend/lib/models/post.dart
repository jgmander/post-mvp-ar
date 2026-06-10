import 'package:cloud_firestore/cloud_firestore.dart';

class Post {
  final String? id;
  final double latitude;
  final double longitude;
  final double altitude;
  final String messageContent;
  final String creatorId;
  final String? ownerId;
  final String visibilityType;
  final int reach;
  final int uniqueViews;
  final String? ctaText;
  final String? ctaAction;
  final bool isSafe;
  final bool isFlagged;
  final String? placeName;
  final String? placeCategory;
  final String postType;
  final DateTime? expiresAt;

  Post({
    this.id,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.messageContent,
    required this.creatorId,
    this.ownerId,
    required this.visibilityType,
    this.reach = 0,
    this.uniqueViews = 0,
    this.ctaText,
    this.ctaAction,
    this.isSafe = true,
    this.isFlagged = false,
    this.placeName,
    this.placeCategory,
    this.postType = 'pin',
    this.expiresAt,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    dynamic expiresAtRaw = json['expires_at'];
    DateTime? parsedExpiresAt;
    if (expiresAtRaw != null) {
      if (expiresAtRaw is String) {
        parsedExpiresAt = DateTime.tryParse(expiresAtRaw);
      } else if (expiresAtRaw is Timestamp) {
        parsedExpiresAt = expiresAtRaw.toDate();
      } else {
        parsedExpiresAt = DateTime.now().add(const Duration(hours: 24));
      }
    }

    return Post(
      id: json['id'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      altitude: json['altitude'],
      messageContent: json['caption'] ?? json['message_content'],
      creatorId: json['creator_id'],
      ownerId: json['owner_id'],
      visibilityType: json['visibility_type'],
      reach: json['reach'] ?? 0,
      uniqueViews: json['unique_views'] ?? 0,
      ctaText: json['cta_text'],
      ctaAction: json['cta_action'],
      isSafe: json['is_safe'] ?? true,
      isFlagged: json['is_flagged'] ?? false,
      placeName: json['place_name'],
      placeCategory: json['place_category'],
      postType: json['post_type'] ?? 'pin',
      expiresAt: parsedExpiresAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'caption': messageContent,
      'creator_id': creatorId,
      'owner_id': ownerId,
      'visibility_type': visibilityType,
      'reach': reach,
      'is_flagged': isFlagged,
      'place_name': placeName,
      'place_category': placeCategory,
      'post_type': postType,
      'expires_at': expiresAt?.toIso8601String(),
    };
  }
}
