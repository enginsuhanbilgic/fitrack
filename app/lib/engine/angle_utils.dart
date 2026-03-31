import 'dart:math';
import '../core/constants.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';

/// Pure math helpers — no state, no side effects.

/// Angle at joint B formed by segments BA and BC, in degrees [0..180].
double? angleDeg(PoseLandmark? a, PoseLandmark? b, PoseLandmark? c) {
  if (a == null || b == null || c == null) {
    return null;
  }
  if (a.confidence < kMinLandmarkConfidence ||
      b.confidence < kMinLandmarkConfidence ||
      c.confidence < kMinLandmarkConfidence) {
    return null;
  }

  final bax = a.x - b.x;
  final bay = a.y - b.y;
  final bcx = c.x - b.x;
  final bcy = c.y - b.y;

  final dot = bax * bcx + bay * bcy;
  final mag1 = sqrt(bax * bax + bay * bay);
  final mag2 = sqrt(bcx * bcx + bcy * bcy);
  if (mag1 == 0 || mag2 == 0) return null;

  final cosTheta = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
  return acos(cosTheta) * 180.0 / pi;
}

/// Vertical distance between two landmarks (used for torso length).
double? verticalDist(PoseLandmark? a, PoseLandmark? b) {
  if (a == null || b == null) return null;
  return (a.y - b.y).abs();
}

/// Horizontal displacement of a landmark between two results (for swing/drift).
double? horizontalShift(PoseResult prev, PoseResult curr, int landmarkType) {
  final a = prev.landmark(landmarkType, minConfidence: kMinLandmarkConfidence);
  final b = curr.landmark(landmarkType, minConfidence: kMinLandmarkConfidence);
  if (a == null || b == null) return null;
  return (b.x - a.x).abs();
}
