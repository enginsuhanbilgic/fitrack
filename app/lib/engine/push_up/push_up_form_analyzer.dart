import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';

/// Form analyzer for push-up.
///
/// Frame-level errors (evaluated during BOTTOM and ASCENDING):
///   - Hip sag: |180° - shoulder-hip-ankle angle| > kHipSagDeviation
///
/// Rep-boundary error (evaluated at ASCENDING → IDLE):
///   - Partial ROM: rep completed without elbow angle reaching kPushUpBottomAngle
class PushUpFormAnalyzer extends FormAnalyzerBase {
  double? _minElbowAngle;

  /// Call at IDLE → DESCENDING. The [startSnapshot] is accepted for
  /// base-class compliance but push-up uses only the tracked minimum angle.
  @override
  void onRepStart(PoseResult startSnapshot) => _minElbowAngle = null;

  /// Call every frame during DESCENDING and BOTTOM to track lowest point.
  void trackAngle(double elbowAngle) {
    if (_minElbowAngle == null || elbowAngle < _minElbowAngle!) {
      _minElbowAngle = elbowAngle;
    }
  }

  /// Frame-level evaluation — returns hipSag if active.
  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];

    // Angle at hip in shoulder→hip→ankle triangle.
    // A straight body = 180°. Deviation = |180 - angle|.
    final hipAngle = angleDeg(
      current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
    );

    if (hipAngle != null && (180.0 - hipAngle).abs() > kHipSagDeviation) {
      errors.add(FormError.hipSag);
    }

    return errors;
  }

  /// Rep-boundary evaluation — checks if elbow reached bottom threshold.
  @override
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];
    if (_minElbowAngle != null && _minElbowAngle! >= kPushUpBottomAngle) {
      errors.add(FormError.pushUpShortRom);
    }
    _minElbowAngle = null;
    return errors;
  }

  @override
  void reset() => _minElbowAngle = null;
}
