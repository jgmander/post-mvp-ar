import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/post.dart';
import 'package:frontend/theme/app_theme.dart';

void main() {
  group('Post v1.1 Model & Zero-Regression Invariants', () {
    test('Permanent posts serialize 2099-12-31 sentinel so v1.0 queries match', () {
      final post = Post(
        latitude: 33.9761,
        longitude: -118.4168,
        altitude: AppSizes.eyeLevelPinAltitude,
        messageContent: 'cauliflower tacos!!',
        creatorId: 'uid_1',
        ownerId: 'uid_1',
        visibilityType: '1-to-many',
        isPermanent: true,
        anchorSurface: 'building',
      );

      final json = post.toJson();
      expect(json['is_permanent'], isTrue);
      expect(json['anchor_surface'], 'building');
      expect(json['altitude'], 1.4);
      expect(json['expires_at'], startsWith('2099-12-31'));
      expect(post.isExpired, isFalse);
      expect(post.isLive24h, isFalse);
    });

    test('Legacy v1.0 Firestore docs without is_permanent parse cleanly', () {
      final futureIso = DateTime.now().add(const Duration(hours: 12)).toIso8601String();
      final parsed = Post.fromJson({
        'id': 'legacy_1',
        'latitude': 33.9765,
        'longitude': -118.4171,
        'altitude': 0.0,
        'caption': 'ask for Tommy',
        'creator_id': 'uid_2',
        'visibility_type': '1-to-many',
        'expires_at': futureIso,
      });

      expect(parsed.messageContent, 'ask for Tommy');
      expect(parsed.isPermanent, isFalse);
      expect(parsed.isExpired, isFalse);
      expect(parsed.isLive24h, isTrue);
    });

    test('2099 sentinel timestamps auto-infer isPermanent == true', () {
      final parsed = Post.fromJson({
        'id': 'perm_1',
        'latitude': 33.9765,
        'longitude': -118.4171,
        'altitude': 15.0,
        'post_type': 'balloon',
        'caption': 'hidden playground!',
        'creator_id': 'uid_3',
        'visibility_type': '1-to-many',
        'expires_at': '2099-12-31T00:00:00Z',
      });

      expect(parsed.isPermanent, isTrue);
      expect(parsed.isExpired, isFalse);
      expect(parsed.isLive24h, isFalse);
    });
  });
}
