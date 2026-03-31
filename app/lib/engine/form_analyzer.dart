import '../core/constants.dart';
import '../core/types.dart';
import '../models/landmark_types.dart';
import '../models/pose_result.dart';
import 'angle_utils.dart';

/// Checks form errors on the current frame against a reference (start-of-rep).
class FormAnalyzer {
  PoseResult? _repStartSnapshot;

  /// Call at the start of each rep (IDLE → CONCENTRIC).
  void onRepStart(PoseResult snapshot) {
    _repStartSnapshot = snapshot;
  }

  /// Call at the end of each rep to clear state.
  void onRepEnd() {
    _repStartSnapshot = null;
  }

  /// Evaluate form on the current frame. Returns active errors (may be empty).
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];
    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    // Torso length for normalisation.
    final shoulder = current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence);
    final hip = current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence);
    final torsoLen = verticalDist(shoulder, hip);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // ── Torso swing ──
    final shoulderShift = horizontalShift(ref, current, LM.leftShoulder);
    if (shoulderShift != null && shoulderShift / torsoLen > kSwingThreshold) {
      errors.add(FormError.torsoSwing);
    }

    // ── Elbow drift ──
    final elbowShift = horizontalShift(ref, current, LM.leftElbow);
    if (elbowShift != null && elbowShift / torsoLen > kDriftThreshold) {
      errors.add(FormError.elbowDrift);
    }

    return errors;
  }

  void reset() {
    _repStartSnapshot = null;
  }
}
