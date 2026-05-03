import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';

/// Form analyzer for squat.
///
/// Frame-level errors (evaluated during ASCENDING):
///   - Trunk-tibia deviation: |θ_trunk - θ_tibia| > kTrunkTibiaDeviation
///
/// Rep-boundary error (evaluated at ASCENDING → IDLE):
///   - Squat depth: rep completed without knee angle ever reaching effectiveBottomAngle
class SquatFormAnalyzer {
  double? _minKneeAngle;

  /// Call at IDLE → DESCENDING.
  void onRepStart() => _minKneeAngle = null;

  /// Call every frame during DESCENDING and BOTTOM to track lowest point.
  void trackAngle(double kneeAngle) {
    if (_minKneeAngle == null || kneeAngle < _minKneeAngle!) {
      _minKneeAngle = kneeAngle;
    }
  }

  /// Frame-level evaluation — returns trunkTibia if active.
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];

    final trunk = angleToVertical(
          current.landmark(LM.leftShoulder,  minConfidence: kMinLandmarkConfidence),
          current.landmark(LM.leftHip,       minConfidence: kMinLandmarkConfidence),
        ) ??
        angleToVertical(
          current.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
          current.landmark(LM.rightHip,      minConfidence: kMinLandmarkConfidence),
        );
    final tibia = angleToVertical(
          current.landmark(LM.leftKnee,  minConfidence: kMinLandmarkConfidence),
          current.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
        ) ??
        angleToVertical(
          current.landmark(LM.rightKnee,  minConfidence: kMinLandmarkConfidence),
          current.landmark(LM.rightAnkle, minConfidence: kMinLandmarkConfidence),
        );

    if (trunk != null && tibia != null && (trunk - tibia).abs() > kTrunkTibiaDeviation) {
      errors.add(FormError.trunkTibia);
    }

    return errors;
  }

  /// Rep-boundary evaluation — checks if depth was reached.
  /// Pass [effectiveBottomAngle] to respect long-femur adaptation.
  List<FormError> consumeCompletionErrors(double effectiveBottomAngle) {
    final errors = <FormError>[];
    if (_minKneeAngle != null && _minKneeAngle! >= effectiveBottomAngle) {
      errors.add(FormError.squatDepth);
    }
    _minKneeAngle = null;
    return errors;
  }

  void reset() => _minKneeAngle = null;
}
