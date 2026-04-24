import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';

/// Form analyzer for squat.
///
/// Frame-level errors (evaluated during ASCENDING):
///   - Trunk-tibia deviation: |θ_trunk - θ_tibia| > kTrunkTibiaDeviation
///
/// Rep-boundary error (evaluated at ASCENDING → IDLE):
///   - Squat depth: rep completed without knee angle ever reaching effectiveBottomAngle
class SquatFormAnalyzer extends FormAnalyzerBase {
  double? _minKneeAngle;

  /// Call at IDLE → DESCENDING. The [startSnapshot] is accepted for
  /// base-class compliance but squat uses only the tracked minimum angle.
  @override
  void onRepStart(PoseResult startSnapshot) => _minKneeAngle = null;

  /// Call every frame during DESCENDING and BOTTOM to track lowest point.
  void trackAngle(double kneeAngle) {
    if (_minKneeAngle == null || kneeAngle < _minKneeAngle!) {
      _minKneeAngle = kneeAngle;
    }
  }

  /// Frame-level evaluation — returns trunkTibia if active.
  @override
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];

    final trunk = angleToVertical(
      current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
    );
    final tibia = angleToVertical(
      current.landmark(LM.leftKnee, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
    );

    if (trunk != null &&
        tibia != null &&
        (trunk - tibia).abs() > kTrunkTibiaDeviation) {
      errors.add(FormError.trunkTibia);
    }

    return errors;
  }

  /// Base-contract stub. Squat completion requires the effective bottom
  /// angle (long-femur adaptation), so callers must use
  /// [consumeCompletionErrorsWithDepth] instead. Kept only to satisfy the
  /// [FormAnalyzerBase] interface — strategies never invoke this path.
  @override
  List<FormError> consumeCompletionErrors() {
    throw UnsupportedError(
      'SquatFormAnalyzer requires effectiveBottomAngle — '
      'call consumeCompletionErrorsWithDepth instead.',
    );
  }

  /// Rep-boundary evaluation — checks if depth was reached.
  /// Pass [effectiveBottomAngle] to respect long-femur adaptation.
  List<FormError> consumeCompletionErrorsWithDepth(
    double effectiveBottomAngle,
  ) {
    final errors = <FormError>[];
    if (_minKneeAngle != null && _minKneeAngle! >= effectiveBottomAngle) {
      errors.add(FormError.squatDepth);
    }
    _minKneeAngle = null;
    return errors;
  }

  @override
  void reset() => _minKneeAngle = null;
}
