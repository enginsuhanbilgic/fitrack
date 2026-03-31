import 'package:flutter/material.dart';
import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';

/// Draws the skeleton overlay on top of the camera preview.
class SkeletonPainter extends CustomPainter {
  final List<PoseLandmark> landmarks;
  final bool mirror;

  SkeletonPainter({required this.landmarks, this.mirror = true});

  static const double _minScore = 0.3;

  final _bonePaint = Paint()
    ..color = const Color(0xFF00E676)
    ..strokeWidth = 3.0
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;

  final _jointPaint = Paint()
    ..color = const Color(0xFF00BCD4)
    ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    final byType = <int, PoseLandmark>{};
    for (final lm in landmarks) {
      byType[lm.type] = lm;
    }

    // Draw bones.
    for (final (startIdx, endIdx) in LM.connections) {
      final a = byType[startIdx];
      final b = byType[endIdx];
      if (a == null || b == null) continue;
      if (a.confidence < _minScore || b.confidence < _minScore) continue;

      canvas.drawLine(
        _toOffset(a, size),
        _toOffset(b, size),
        _bonePaint,
      );
    }

    // Draw joints.
    for (final lm in landmarks) {
      if (lm.confidence < _minScore) continue;
      canvas.drawCircle(_toOffset(lm, size), 5, _jointPaint);
    }
  }

  Offset _toOffset(PoseLandmark lm, Size size) {
    final x = mirror ? (1.0 - lm.x) : lm.x;
    return Offset(x * size.width, lm.y * size.height);
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter old) => true;
}
