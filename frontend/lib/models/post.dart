import 'package:cloud_firestore/cloud_firestore.dart';

class Post {
  /// Sentinel far-future timestamp so v1.0 clients querying `expires_at > now`
  /// continue to see permanent posts seamlessly.
  static final DateTime permanentSentinel = DateTime.utc(2099, 12, 31);

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
  final String? actionUrl;
  final bool isSafe;
  final bool isFlagged;
  final String? placeName;
  final String? placeCategory;
  final String postType;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final bool isPermanent;
  final String? anchorSurface;

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
    this.actionUrl,
    this.isSafe = true,
    this.isFlagged = false,
    this.placeName,
    this.placeCategory,
    this.postType = 'pin',
    this.expiresAt,
    this.createdAt,
    this.isPermanent = false,
    this.anchorSurface,
  });

  bool get isExpired {
    if (isPermanent) return false;
    if (expiresAt == null) return false;
    if (expiresAt!.year >= 2090) return false;
    return expiresAt!.isBefore(DateTime.now());
  }

  bool get isLive24h => !isPermanent && (expiresAt == null || expiresAt!.year < 2028);

  static DateTime? _parseTimestamp(dynamic raw) {
    if (raw == null) return null;
    if (raw is Timestamp) return raw.toDate();
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  factory Post.fromJson(Map<String, dynamic> json) {
    final parsedExpiresAt = _parseTimestamp(json['expires_at']);
    final parsedCreatedAt = _parseTimestamp(json['created_at']);
    final explicitPerm = json['is_permanent'] == true;
    final inferredPerm = explicitPerm ||
        (parsedExpiresAt != null && parsedExpiresAt.year >= 2090);

    return Post(
      id: json['id'],
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      altitude: (json['altitude'] as num).toDouble(),
      messageContent: (json['caption'] ?? json['message_content'] ?? '') as String,
      creatorId: (json['creator_id'] ?? 'anonymous') as String,
      ownerId: json['owner_id'] as String?,
      visibilityType: (json['visibility_type'] ?? '1-to-many') as String,
      reach: (json['reach'] as num?)?.toInt() ?? 0,
      uniqueViews: (json['unique_views'] as num?)?.toInt() ?? 0,
      ctaText: json['cta_text'] as String?,
      ctaAction: json['cta_action'] as String?,
      actionUrl: json['action_url'] as String?,
      isSafe: json['is_safe'] ?? true,
      isFlagged: json['is_flagged'] ?? false,
      placeName: json['place_name'] as String?,
      placeCategory: json['place_category'] as String?,
      postType: (json['post_type'] ?? 'pin') as String,
      expiresAt: parsedExpiresAt,
      createdAt: parsedCreatedAt,
      isPermanent: inferredPerm,
      anchorSurface: json['anchor_surface'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final effectiveExpiry = isPermanent
        ? permanentSentinel
        : (expiresAt ?? DateTime.now().toUtc().add(const Duration(hours: 24)));
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
      'is_permanent': isPermanent,
      if (anchorSurface != null) 'anchor_surface': anchorSurface,
      if (actionUrl != null && actionUrl!.isNotEmpty) 'action_url': actionUrl,
      'expires_at': effectiveExpiry.toUtc().toIso8601String(),
    };
  }
}
