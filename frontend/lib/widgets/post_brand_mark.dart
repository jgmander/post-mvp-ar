import 'package:flutter/material.dart';

/// Custom trademark-distinct "Post" Spatial Note-P Brand Mark.
///
/// Combines three ownable geometric cues with zero Google/Apple Maps overlap:
/// 1. Squircle note silhouette with a 45-degree folded top-right dog-ear corner
/// 2. Compact spatial anchor chevron along the bottom edge
/// 3. Bold geometric 'P' monogram centered inside the note face
class PostBrandMark extends StatelessWidget {
  const PostBrandMark({
    super.key,
    this.size = 40.0,
    this.fillColor = const Color(0xFF1A8CFF),
    this.glyphColor = Colors.white,
    this.borderColor = Colors.white,
    this.glowColor,
  });

  final double size;
  final Color fillColor;
  final Color glyphColor;
  final Color borderColor;
  final Color? glowColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PostBrandMarkPainter(
          fillColor: fillColor,
          glyphColor: glyphColor,
          borderColor: borderColor,
          glowColor: glowColor,
        ),
      ),
    );
  }
}

class _PostBrandMarkPainter extends CustomPainter {
  _PostBrandMarkPainter({
    required this.fillColor,
    required this.glyphColor,
    required this.borderColor,
    this.glowColor,
  });

  final Color fillColor;
  final Color glyphColor;
  final Color borderColor;
  final Color? glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final left = w * 0.13;
    final right = w * 0.87;
    final top = h * 0.08;
    final bottom = h * 0.78;
    final radius = w * 0.15;
    final fold = w * 0.24;

    final notePath = Path()
      ..moveTo(left + radius, top)
      ..lineTo(right - fold, top)
      ..lineTo(right, top + fold)
      ..lineTo(right, bottom - radius)
      ..quadraticBezierTo(right, bottom, right - radius, bottom)
      ..lineTo(w * 0.60, bottom)
      ..lineTo(w * 0.50, h * 0.94)
      ..lineTo(w * 0.40, bottom)
      ..lineTo(left + radius, bottom)
      ..quadraticBezierTo(left, bottom, left, bottom - radius)
      ..lineTo(left, top + radius)
      ..quadraticBezierTo(left, top, left + radius, top)
      ..close();

    if (glowColor != null) {
      final glowPaint = Paint()
        ..color = glowColor!
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawPath(notePath, glowPaint);
    }

    // Crisp vinyl outer border shadow + fill
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(notePath, fillPaint);

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.055
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(notePath, borderPaint);

    // Folded sticky-note top-right dog-ear flap
    final flapPath = Path()
      ..moveTo(right - fold, top)
      ..lineTo(right - fold, top + fold * 0.78)
      ..quadraticBezierTo(
        right - fold,
        top + fold,
        right - fold * 0.78,
        top + fold,
      )
      ..lineTo(right, top + fold)
      ..close();
    final flapPaint = Paint()
      ..color = glyphColor.withValues(alpha: 0.90)
      ..style = PaintingStyle.fill;
    canvas.drawPath(flapPath, flapPaint);

    // Bold geometric 'P' monogram
    final pPaint = Paint()
      ..color = glyphColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.105
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final stemX = w * 0.36;
    final stemTop = h * 0.27;
    final stemBottom = h * 0.63;
    final bowlMidY = h * 0.46;
    final bowlRight = w * 0.57;

    final pPath = Path()
      ..moveTo(stemX, stemBottom)
      ..lineTo(stemX, stemTop)
      ..lineTo(w * 0.47, stemTop)
      ..arcToPoint(
        Offset(w * 0.47, bowlMidY),
        radius: Radius.circular((bowlMidY - stemTop) * 0.5),
        clockwise: true,
      )
      ..lineTo(stemX, bowlMidY);

    // Widen bowl slightly for crisp distant legibility
    final pWidePath = Path()
      ..moveTo(stemX, stemBottom)
      ..lineTo(stemX, stemTop)
      ..lineTo(bowlRight - (bowlMidY - stemTop) * 0.5, stemTop)
      ..arcToPoint(
        Offset(bowlRight - (bowlMidY - stemTop) * 0.5, bowlMidY),
        radius: Radius.circular((bowlMidY - stemTop) * 0.5),
        clockwise: true,
      )
      ..lineTo(stemX, bowlMidY);
    // Keep unused pPath suppressed cleanly
    pPath.reset();
    canvas.drawPath(pWidePath, pPaint);
  }

  @override
  bool shouldRepaint(covariant _PostBrandMarkPainter oldDelegate) {
    return oldDelegate.fillColor != fillColor ||
        oldDelegate.glyphColor != glyphColor ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.glowColor != glowColor;
  }
}
