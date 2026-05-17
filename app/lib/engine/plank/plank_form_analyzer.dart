import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import '../form_analyzer_base.dart';

class PlankSecondSample {
  const PlankSecondSample({
    required this.index,
    required this.quality,
    required this.valid,
  });

  final int index;
  final double quality;
  final bool valid;
}

/// Frame-level analyzer for a side-view forearm plank.
///
/// A clean hold requires both:
/// - elbows near 90 degrees with the shoulder roughly stacked above the elbow;
/// - shoulder, hip, and ankle staying close to a straight line.
class PlankFormAnalyzer extends FormAnalyzerBase {
  double? _lastQuality;
  bool _lastValid = false;

  double? get lastQuality => _lastQuality;
  bool get lastValid => _lastValid;

  @override
  void onRepStart(PoseResult startSnapshot) {
    // Plank is a timed hold, not a rep cycle. Per-frame evaluation owns all
    // state, but the shared analyzer contract still requires this hook.
  }

  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];

    final arm = _bestArm(current);
    final body = _bestBodyLine(current);

    var quality = 1.0;
    if (arm == null || !arm.valid) {
      errors.add(FormError.plankArmAngle);
      quality -= arm?.deduction ?? kQualityPlankArmMaxDeduction;
    }
    if (body == null || body.deviationDeg > kPlankBodyLineDeviation) {
      errors.add(FormError.plankBodyLine);
      final deviation = body?.deviationDeg ?? (kPlankBodyLineDeviation * 2);
      final severity = ((deviation - kPlankBodyLineDeviation) /
              kPlankBodyLineDeviation)
          .clamp(0.0, 1.0);
      quality -= kQualityPlankBodyLineMaxDeduction * severity;
    }

    _lastQuality = quality.clamp(0.0, 1.0);
    _lastValid = errors.isEmpty;
    return errors;
  }

  @override
  List<FormError> consumeCompletionErrors() => const [];

  @override
  void reset() {
    _lastQuality = null;
    _lastValid = false;
  }

  _ArmCandidate? _bestArm(PoseResult p) {
    final left = _armCandidate(p, isLeft: true);
    final right = _armCandidate(p, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right;
    if (right == null) return left;
    return left.confidenceSum >= right.confidenceSum ? left : right;
  }

  _ArmCandidate? _armCandidate(PoseResult p, {required bool isLeft}) {
    final shoulder = p.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final elbow = p.landmark(
      isLeft ? LM.leftElbow : LM.rightElbow,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final wrist = p.landmark(
      isLeft ? LM.leftWrist : LM.rightWrist,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final elbowAngle = _angleDeg(shoulder, elbow, wrist);
    if (shoulder == null ||
        elbow == null ||
        hip == null) {
      return null;
    }

    final torsoLen = _distance(shoulder, hip);
    final stackRatio = torsoLen <= 0
        ? double.infinity
        : (shoulder.x - elbow.x).abs() / torsoLen;
    final angleBad = elbowAngle != null &&
        (elbowAngle < kPlankElbowMinAngle ||
            elbowAngle > kPlankElbowMaxAngle);
    final stackBad = stackRatio > kPlankShoulderElbowMaxOffsetRatio;
    final angleSeverity = elbowAngle == null
        ? 0.0
        : elbowAngle < kPlankElbowMinAngle
            ? (kPlankElbowMinAngle - elbowAngle) / 45.0
            : (elbowAngle - kPlankElbowMaxAngle) / 45.0;
    final stackSeverity =
        (stackRatio - kPlankShoulderElbowMaxOffsetRatio) /
        kPlankShoulderElbowMaxOffsetRatio;
    final severity = math.max(
      angleBad ? angleSeverity : 0,
      stackBad ? stackSeverity : 0,
    );

    return _ArmCandidate(
      valid: !angleBad && !stackBad,
      deduction: kQualityPlankArmMaxDeduction * severity.clamp(0.0, 1.0),
      confidenceSum:
          shoulder.confidence + elbow.confidence + (wrist?.confidence ?? 0.0),
    );
  }

  _BodyLineCandidate? _bestBodyLine(PoseResult p) {
    final left = _bodyLineCandidate(p, isLeft: true);
    final right = _bodyLineCandidate(p, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right;
    if (right == null) return left;
    return left.confidenceSum >= right.confidenceSum ? left : right;
  }

  _BodyLineCandidate? _bodyLineCandidate(PoseResult p, {required bool isLeft}) {
    final shoulder = p.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final knee = p.landmark(
      isLeft ? LM.leftKnee : LM.rightKnee,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final lowerBody = ankle ?? knee;
    final hipAngle = _angleDeg(shoulder, hip, lowerBody);
    if (shoulder == null ||
        hip == null ||
        lowerBody == null ||
        hipAngle == null) {
      return null;
    }
    return _BodyLineCandidate(
      deviationDeg: (180.0 - hipAngle).abs(),
      confidenceSum:
          shoulder.confidence + hip.confidence + lowerBody.confidence,
    );
  }

  double _distance(PoseLandmark a, PoseLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  double? _angleDeg(PoseLandmark? a, PoseLandmark? b, PoseLandmark? c) {
    if (a == null || b == null || c == null) return null;

    final bax = a.x - b.x;
    final bay = a.y - b.y;
    final bcx = c.x - b.x;
    final bcy = c.y - b.y;

    final mag1 = math.sqrt(bax * bax + bay * bay);
    final mag2 = math.sqrt(bcx * bcx + bcy * bcy);
    if (mag1 == 0 || mag2 == 0) return null;
    if (mag1 < kMinJointSegmentLength || mag2 < kMinJointSegmentLength) {
      return null;
    }

    final ratio = mag1 > mag2 ? mag1 / mag2 : mag2 / mag1;
    if (ratio > kMaxJointSegmentRatio) return null;

    final dot = bax * bcx + bay * bcy;
    final cosTheta = (dot / (mag1 * mag2)).clamp(-1.0, 1.0);
    return math.acos(cosTheta) * 180.0 / math.pi;
  }
}

class _ArmCandidate {
  const _ArmCandidate({
    required this.valid,
    required this.deduction,
    required this.confidenceSum,
  });

  final bool valid;
  final double deduction;
  final double confidenceSum;
}

class _BodyLineCandidate {
  const _BodyLineCandidate({
    required this.deviationDeg,
    required this.confidenceSum,
  });

  final double deviationDeg;
  final double confidenceSum;
}
