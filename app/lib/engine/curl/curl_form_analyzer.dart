import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';

/// Form analyzer for biceps curl.
///
/// Frame-level errors (evaluated every frame during CONCENTRIC/ECCENTRIC):
///   - Torso swing: ΔX_shoulder / L_torso > kSwingThreshold
///   - Elbow drift: ΔX_elbow / L_torso > kDriftThreshold
///
/// Rep-boundary error (evaluated once per abandoned rep):
///   - Short ROM: rep started (CONCENTRIC) but reversed before reaching PEAK
class CurlFormAnalyzer {
  PoseResult? _repStartSnapshot;
  bool _shortRomPending = false;

  /// Call at IDLE → CONCENTRIC.
  void onRepStart(PoseResult snapshot) {
    _repStartSnapshot = snapshot;
    _shortRomPending = false;
  }

  /// Call when CONCENTRIC → IDLE without having reached PEAK (abandoned rep).
  void onAbortedRep() {
    _shortRomPending = true;
  }

  /// Call at the end of each completed rep to clear state.
  void onRepEnd() {
    _repStartSnapshot = null;
    _shortRomPending = false;
  }

  /// Frame-level evaluation — returns torsoSwing / elbowDrift if active.
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];
    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    // Torso length for normalisation (L_torso) — bilateral average.
    final leftLen = verticalDist(
      current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
    );
    final rightLen = verticalDist(
      current.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence),
    );
    final double? torsoLen;
    if (leftLen != null && rightLen != null) {
      torsoLen = (leftLen + rightLen) / 2.0;
    } else {
      torsoLen = leftLen ?? rightLen;
    }
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Torso swing
    final leftSwing = horizontalShift(ref, current, LM.leftShoulder);
    final rightSwing = horizontalShift(ref, current, LM.rightShoulder);
    final bestSwing = leftSwing ?? rightSwing;
    if (bestSwing != null && bestSwing / torsoLen > kSwingThreshold) {
      errors.add(FormError.torsoSwing);
    }

    // Elbow drift
    final leftDrift = horizontalShift(ref, current, LM.leftElbow);
    final rightDrift = horizontalShift(ref, current, LM.rightElbow);
    final bestDrift = leftDrift ?? rightDrift;
    if (bestDrift != null && bestDrift / torsoLen > kDriftThreshold) {
      errors.add(FormError.elbowDrift);
    }

    return errors;
  }

  /// Rep-boundary evaluation — drains one-shot errors (shortRom).
  /// Call once at ECCENTRIC → IDLE or on aborted rep detection.
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];
    if (_shortRomPending) {
      errors.add(FormError.shortRom);
      _shortRomPending = false;
    }
    return errors;
  }

  void reset() {
    _repStartSnapshot = null;
    _shortRomPending = false;
  }
}
