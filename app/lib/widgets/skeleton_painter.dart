import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';

/// Draws the skeleton overlay on top of the camera preview.
class SkeletonPainter extends CustomPainter {
  final List<PoseLandmark> landmarks;
  final bool mirror;

  /// Optional per-landmark color override keyed by ML Kit landmark index.
  /// When provided, joints use the mapped color instead of the default cyan.
  /// Bone connections use the override color only if both endpoints share the
  /// same override color; otherwise the default green is used.
  final Map<int, Color>? landmarkColors;

  /// Which bone connections to draw. Defaults to full skeleton.
  final List<(int, int)> boneConnections;

  /// Optional set of landmark indices to draw. If null, defaults to
  /// [LM.bodyOnlyLandmarks] (no face/hands).
  final Set<int> visibleLandmarks;

  /// When set, draws an angle arc annotation at the elbow joint (design
  /// "Overlay" variant). Tuple: (landmarkIndex, angleDegrees).
  final (int, double)? elbowAngleAnnotation;

  /// Base color used for bones and joint rings when no per-landmark override
  /// is present. Pass [FiTrackColors.of(context).accent] from the widget tree.
  final Color boneColor;

  SkeletonPainter({
    required this.landmarks,
    this.mirror = true,
    this.landmarkColors,
    List<(int, int)>? boneConnections,
    Set<int>? visibleLandmarks,
    this.elbowAngleAnnotation,
    Color? boneColor,
  }) : boneConnections = boneConnections ?? LM.connections,
       visibleLandmarks = visibleLandmarks ?? LM.bodyOnlyLandmarks,
       boneColor = boneColor ?? const Color(0xFFC3F400);

  static const double _minScore = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    final byType = <int, PoseLandmark>{};
    for (final lm in landmarks) {
      byType[lm.type] = lm;
    }

    // Draw bones — glow under-layer then crisp top line.
    for (final (startIdx, endIdx) in boneConnections) {
      final a = byType[startIdx];
      final b = byType[endIdx];
      if (a == null || b == null) continue;
      if (a.confidence < _minScore || b.confidence < _minScore) continue;

      final colorA = landmarkColors?[startIdx];
      final colorB = landmarkColors?[endIdx];
      final resolvedBoneColor = (colorA != null && colorA == colorB)
          ? colorA
          : boneColor;

      final from = _toOffset(a, size);
      final to = _toOffset(b, size);

      // Glow halo.
      canvas.drawLine(
        from,
        to,
        Paint()
          ..color = resolvedBoneColor.withAlpha(0x66)
          ..strokeWidth = 10.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      // Crisp core.
      canvas.drawLine(
        from,
        to,
        Paint()
          ..color = resolvedBoneColor
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // Draw joints — hollow ring with glow.
    for (final lm in landmarks) {
      if (lm.confidence < _minScore) continue;
      if (!visibleLandmarks.contains(lm.type)) continue;
      final jointColor = landmarkColors?[lm.type] ?? boneColor;
      final center = _toOffset(lm, size);

      // Glow halo.
      canvas.drawCircle(
        center,
        7,
        Paint()
          ..color = jointColor.withAlpha(0x55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8.0
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      // Hollow ring — transparent fill, glowing stroke.
      canvas.drawCircle(
        center,
        5,
        Paint()
          ..color = jointColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    // Overlay angle arc annotation at elbow joint.
    if (elbowAngleAnnotation != null) {
      final (elbowIdx, angleDeg) = elbowAngleAnnotation!;
      final elbow = byType[elbowIdx];
      if (elbow != null && elbow.confidence >= _minScore) {
        _drawAngleArc(canvas, size, elbow, angleDeg);
      }
    }
  }

  /// Draws a dashed arc + degree label radiating from the elbow joint,
  /// matching the design "Overlay" skeleton annotation style.
  void _drawAngleArc(
    Canvas canvas,
    Size size,
    PoseLandmark elbow,
    double angleDeg,
  ) {
    final center = _toOffset(elbow, size);
    const arcRadius = 36.0;
    const arcSweepRad = math.pi / 3; // 60° sweep for the arc glyph

    // Dashed arc — draw as short stroke segments.
    final arcPaint = Paint()
      ..color = boneColor.withAlpha(0xCC)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const dashCount = 6;
    const gapFraction = 0.35;
    const startAngle = -math.pi / 2; // pointing up

    for (int i = 0; i < dashCount; i++) {
      final t0 = startAngle + (i / dashCount) * arcSweepRad;
      final t1 = t0 + (arcSweepRad / dashCount) * (1 - gapFraction);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: arcRadius),
        t0,
        t1 - t0,
        false,
        arcPaint,
      );
    }

    // Degree label — positioned to the upper-right of the arc.
    final labelOffset = Offset(
      center.dx + arcRadius * 0.85,
      center.dy - arcRadius * 0.9,
    );
    _drawAngleLabel(canvas, '${angleDeg.round()}°', labelOffset);
  }

  void _drawAngleLabel(Canvas canvas, String text, Offset position) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: boneColor,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Pill background behind the label for legibility over busy camera feed.
    const pad = 4.0;
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        position.dx - pad,
        position.dy - pad,
        tp.width + pad * 2,
        tp.height + pad * 2,
      ),
      const Radius.circular(4),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xBB0A0A0A));
    tp.paint(canvas, position);
  }

  Offset _toOffset(PoseLandmark lm, Size size) {
    final x = mirror ? (1.0 - lm.x) : lm.x;
    return Offset(x * size.width, lm.y * size.height);
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter old) => true;
}
