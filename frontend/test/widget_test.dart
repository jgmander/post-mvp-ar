import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/post_brand_mark.dart';

void main() {
  testWidgets('PostBrandMark renders custom trademark-distinct spatial badge', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PostBrandMark(
              size: 48,
              fillColor: AppColors.ownPost,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(PostBrandMark), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
