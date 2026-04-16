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

  /// Optional set of landmark indices to draw. If null, draws all.
  final Set<int>? visibleLandmarks;

  SkeletonPainter({
    required this.landmarks,
    this.mirror = true,
    this.landmarkColors,
    List<(int, int)>? boneConnections,
    this.visibleLandmarks,
  }) : boneConnections = boneConnections ?? LM.connections;

  static const double _minScore = 0.3;

  static const Color _defaultBoneColor = Color(0xFF00E676);
  static const Color _defaultJointColor = Color(0xFF00BCD4);

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    final byType = <int, PoseLandmark>{};
    for (final lm in landmarks) {
      byType[lm.type] = lm;
    }

    // Draw bones.
    for (final (startIdx, endIdx) in boneConnections) {
      final a = byType[startIdx];
      final b = byType[endIdx];
      if (a == null || b == null) continue;
      if (a.confidence < _minScore || b.confidence < _minScore) continue;

      final colorA = landmarkColors?[startIdx];
      final colorB = landmarkColors?[endIdx];
      final boneColor = (colorA != null && colorA == colorB)
          ? colorA
          : _defaultBoneColor;

      canvas.drawLine(
        _toOffset(a, size),
        _toOffset(b, size),
        Paint()
          ..color = boneColor
          ..strokeWidth = 3.0
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // Draw joints.
    for (final lm in landmarks) {
      if (lm.confidence < _minScore) continue;
      if (visibleLandmarks != null && !visibleLandmarks!.contains(lm.type)) continue;
      final jointColor = landmarkColors?[lm.type] ?? _defaultJointColor;
      canvas.drawCircle(
        _toOffset(lm, size),
        5,
        Paint()..color = jointColor..style = PaintingStyle.fill,
      );
    }
  }

  Offset _toOffset(PoseLandmark lm, Size size) {
    final x = mirror ? (1.0 - lm.x) : lm.x;
    return Offset(x * size.width, lm.y * size.height);
  }

  @override
  bool shouldRepaint(covariant SkeletonPainter old) => true;
}
