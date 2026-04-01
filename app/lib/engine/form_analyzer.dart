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

    // Torso length for normalisation (L_torso).
    // Try to get max confidence side for scale baseline.
    final leftShoulder = current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence);
    final leftHip = current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence);
    final rightShoulder = current.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence);
    final rightHip = current.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence);

    final leftLen = verticalDist(leftShoulder, leftHip);
    final rightLen = verticalDist(rightShoulder, rightHip);
    
    // Fallback: pick the best visible side or average if both are good.
    final double? torsoLen;
    if (leftLen != null && rightLen != null) {
      torsoLen = (leftLen + rightLen) / 2.0;
    } else {
      torsoLen = leftLen ?? rightLen;
    }

    if (torsoLen == null || torsoLen < 0.01) return errors;

    // ── Torso swing (use most confident side acromion displacement) ──
    final leftSwing = horizontalShift(ref, current, LM.leftShoulder);
    final rightSwing = horizontalShift(ref, current, LM.rightShoulder);
    final bestSwing = leftSwing ?? rightSwing;

    if (bestSwing != null && bestSwing / torsoLen > kSwingThreshold) {
      errors.add(FormError.torsoSwing);
    }

    // ── Elbow drift (use most confident side elbow displacement) ──
    final leftDrift = horizontalShift(ref, current, LM.leftElbow);
    final rightDrift = horizontalShift(ref, current, LM.rightElbow);
    final bestDrift = leftDrift ?? rightDrift;

    if (bestDrift != null && bestDrift / torsoLen > kDriftThreshold) {
      errors.add(FormError.elbowDrift);
    }

    return errors;
  }

  void reset() {
    _repStartSnapshot = null;
  }
}
