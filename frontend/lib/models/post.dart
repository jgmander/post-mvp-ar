class Post {
  final String? id;
  final double latitude;
  final double longitude;
  final double altitude;
  final String messageContent;
  final String creatorId;
  final String visibilityType;
  final int reach;
  final int uniqueViews;
  final String? ctaText;
  final String? ctaAction;
  final bool isSafe;

  Post({
    this.id,
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.messageContent,
    required this.creatorId,
    required this.visibilityType,
    this.reach = 0,
    this.uniqueViews = 0,
    this.ctaText,
    this.ctaAction,
    this.isSafe = true,
  });

  factory Post.fromJson(Map<String, dynamic> json) {
    return Post(
      id: json['id'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      altitude: json['altitude'],
      messageContent: json['message_content'],
      creatorId: json['creator_id'],
      visibilityType: json['visibility_type'],
      reach: json['reach'] ?? 0,
      uniqueViews: json['unique_views'] ?? 0,
      ctaText: json['cta_text'],
      ctaAction: json['cta_action'],
      isSafe: json['is_safe'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'message_content': messageContent,
      'creator_id': creatorId,
      'visibility_type': visibilityType,
      'reach': reach,
    };
  }
}
