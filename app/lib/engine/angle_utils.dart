import 'dart:math';
import '../core/constants.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';

/// Pure math helpers — no state, no side effects.

/// Angle at joint B formed by segments BA and BC, in degrees [0..180].
///
/// Returns null when the triangle is degenerate — any of:
///   - missing or low-confidence landmark (existing rule);
///   - either segment shorter than [kMinJointSegmentLength] (one landmark
///     snapped onto another — common at peak flexion when the wrist
///     occludes against the bicep);
///   - segment-length ratio exceeds [kMaxJointSegmentRatio] (one limb
///     measured implausibly short relative to the other — pathological
///     pose, not real biomechanics).
///
/// These guards prevent the artifact `min=3°` readings observed in
/// front-view curl sessions where ML Kit briefly snapped the wrist onto
/// the shoulder at peak flexion. The FSM previously latched those spurious
/// extremes as the rep's true min/max.
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

  // Sanity: both segments must be long enough to represent a real limb.
  if (mag1 < kMinJointSegmentLength || mag2 < kMinJointSegmentLength) {
    return null;
  }

  // Sanity: segment lengths must be in a plausible ratio. A real elbow at
  // peak flexion gives ratios up to ~2.5; a snapped wrist gives 10× or
  // more.
  final ratio = mag1 > mag2 ? mag1 / mag2 : mag2 / mag1;
  if (ratio > kMaxJointSegmentRatio) {
    return null;
  }

  final cosTheta = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
  return acos(cosTheta) * 180.0 / pi;
}

/// Vertical distance between two landmarks (used for torso length).
double? verticalDist(PoseLandmark? a, PoseLandmark? b) {
  if (a == null || b == null) return null;
  return (a.y - b.y).abs();
}

/// Angle of segment (a→b) relative to vertical, in degrees [0..90].
/// Used for trunk-tibia parallelism check in squat form analysis.
double? angleToVertical(PoseLandmark? a, PoseLandmark? b) {
  if (a == null || b == null) return null;
  final dx = (b.x - a.x).abs();
  final dy = (b.y - a.y).abs();
  if (dy == 0) return 90.0;
  return atan2(dx, dy) * 180.0 / pi;
}

/// Signed angle of segment (a→b) relative to vertical, in degrees [-180..180].
/// b is the pivot (e.g. hip), a is the moving part (e.g. shoulder).
/// Positive values typically mean a moves right relative to b.
double? signedAngleToVertical(PoseLandmark? a, PoseLandmark? b) {
  if (a == null || b == null) return null;
  final dx = a.x - b.x;
  final dy = b.y - a.y; // b is hip (larger y), a is shoulder (smaller y)
  if (dy == 0) return dx >= 0 ? 90.0 : -90.0;
  return atan2(dx, dy) * 180.0 / pi;
}

/// Horizontal displacement of a landmark between two results (for swing/drift).
double? horizontalShift(PoseResult prev, PoseResult curr, int landmarkType) {
  final a = prev.landmark(landmarkType, minConfidence: kMinLandmarkConfidence);
  final b = curr.landmark(landmarkType, minConfidence: kMinLandmarkConfidence);
  if (a == null || b == null) return null;
  return (b.x - a.x).abs();
}
