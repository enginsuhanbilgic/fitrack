import 'package:flutter/material.dart';
import '../models/pose_landmark.dart';
import '../screens/home_screen.dart';
import '../utils/skeleton_connections.dart';

class SkeletonPainter extends CustomPainter {
  final List<PoseLandmark> landmarks;
  final double confidenceThreshold;
  final double? aspectRatio;
  final ExerciseType? exerciseType;

  SkeletonPainter({
    required this.landmarks,
    this.confidenceThreshold = 0.05,
    this.aspectRatio,
    this.exerciseType,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (landmarks.isEmpty) return;

    // Use provided aspect ratio or default to 3/4
    final contentAspect = (aspectRatio != null && aspectRatio! > 0) ? aspectRatio! : (3.0 / 4.0);
    final screenAspect = size.width / size.height;

    double scaleX, scaleY;
    double offsetX = 0, offsetY = 0;

    if (screenAspect > contentAspect) {
      // Screen is wider — fit to width, clip top/bottom
      scaleX = size.width;
      scaleY = size.width / contentAspect;
      offsetY = (size.height - scaleY) / 2;
    } else {
      // Screen is taller — fit to height, clip left/right
      scaleY = size.height;
      scaleX = size.height * contentAspect;
      offsetX = (size.width - scaleX) / 2;
    }

    // Build a quick lookup by type
    final Map<int, PoseLandmark> lmMap = {};
    for (final lm in landmarks) {
      lmMap[lm.type] = lm;
    }

    Offset getPos(PoseLandmark lm) {
      return Offset(
        offsetX + lm.x * scaleX,
        offsetY + lm.y * scaleY,
      );
    }

    // Draw bones
    final bool isMLKit = landmarks.length > 17;
    final List<List<int>> connections;
    final Set<int>? allowedKeypoints;
    if (exerciseType == ExerciseType.bicepCurl) {
      connections = isMLKit ? mlkitBicepCurlSkeletonConnections : bicepCurlSkeletonConnections;
      allowedKeypoints = isMLKit ? mlkitBicepCurlKeypoints : bicepCurlKeypoints;
    } else {
      connections = isMLKit ? mlkitSkeletonConnections : skeletonConnections;
      allowedKeypoints = null;
    }
    for (final conn in connections) {
      final a = lmMap[conn[0]];
      final b = lmMap[conn[1]];
      if (a == null || b == null) continue;
      if (a.confidence < confidenceThreshold || b.confidence < confidenceThreshold) continue;

      final minConf = a.confidence < b.confidence ? a.confidence : b.confidence;
      final paint = Paint()
        ..color = _colorForConfidence(minConf)
        ..strokeWidth = 3.0
        ..style = PaintingStyle.stroke;

      canvas.drawLine(getPos(a), getPos(b), paint);
    }

    // Draw keypoints
    for (final lm in landmarks) {
      if (allowedKeypoints != null && !allowedKeypoints.contains(lm.type)) continue;
      if (lm.confidence < confidenceThreshold) continue;

      final pos = getPos(lm);
      final paint = Paint()
        ..color = _colorForConfidence(lm.confidence)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(pos, 5.0, paint);

      // White border for visibility
      final borderPaint = Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;

      canvas.drawCircle(pos, 5.0, borderPaint);
    }
  }

  Color _colorForConfidence(double conf) {
    if (conf > 0.7) return Colors.greenAccent;
    if (conf > 0.3) return Colors.yellowAccent;
    return Colors.redAccent;
  }

  @override
  bool shouldRepaint(SkeletonPainter oldDelegate) {
    return landmarks != oldDelegate.landmarks || exerciseType != oldDelegate.exerciseType;
  }
}
