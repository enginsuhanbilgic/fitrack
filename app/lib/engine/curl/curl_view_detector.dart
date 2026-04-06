import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';

/// Accumulates geometric evidence over [kViewDetectionFrames] frames and
/// classifies the camera view as front, sideLeft, or sideRight.
///
/// Call [update] once per frame during SETUP_CHECK and COUNTDOWN.
/// Read [detectedView] — returns [CurlCameraView.unknown] until [isLocked].
/// Once locked, [detectedView] never changes. Call [reset] to re-detect.
///
/// Three 2D signals are scored per frame; 2 of 3 must agree to cast a vote:
///   1. Shoulder separation ratio |leftShoulder.x - rightShoulder.x|
///   2. Shoulder confidence asymmetry |leftConf - rightConf|
///   3. Nose offset from shoulder midpoint |(nose.x - midX)|
///
/// [kViewDetectionConsensusFrames] out of [kViewDetectionFrames] votes must
/// agree on the same view to lock. Ambiguous frames cast no vote.
class CurlViewDetector {
  final List<CurlCameraView> _frameVotes = [];
  CurlCameraView _lockedView = CurlCameraView.unknown;
  bool _isLocked = false;

  bool get isLocked => _isLocked;
  CurlCameraView get detectedView => _lockedView;

  /// Feed one pose frame. Returns current locked view (or unknown).
  CurlCameraView update(PoseResult pose) {
    if (_isLocked) return _lockedView;
    final vote = _classifyFrame(pose);
    if (vote != CurlCameraView.unknown) _frameVotes.add(vote);
    if (_frameVotes.length >= kViewDetectionFrames) _tryLock();
    return _lockedView;
  }

  void reset() {
    _frameVotes.clear();
    _lockedView = CurlCameraView.unknown;
    _isLocked = false;
  }

  // ── Internal ─────────────────────────────────────────

  /// Classify a single frame without affecting vote state.
  /// Used by RepCounter during ACTIVE phase for continuous re-detection.
  CurlCameraView classifyFrame(PoseResult pose) => _classifyFrame(pose);

  CurlCameraView _classifyFrame(PoseResult pose) {
    // Raw access without confidence gate — we need raw confidence for asymmetry.
    final ls = pose.landmark(LM.leftShoulder);
    final rs = pose.landmark(LM.rightShoulder);
    if (ls == null || rs == null) return CurlCameraView.unknown;

    final separation = (ls.x - rs.x).abs();
    final confidenceDelta = (ls.confidence - rs.confidence).abs();
    final nose = pose.landmark(LM.nose);
    final noseOffset = nose != null
        ? (nose.x - (ls.x + rs.x) / 2.0).abs()
        : 0.0;

    int sideEvidence = 0;
    if (separation < kSideViewShoulderSepThreshold) sideEvidence++;
    if (confidenceDelta > kViewShoulderConfidenceDeltaThreshold) sideEvidence++;
    if (noseOffset > kViewNoseOffsetThreshold) sideEvidence++;

    int frontEvidence = 0;
    if (separation > kFrontViewShoulderSepThreshold) frontEvidence++;
    if (confidenceDelta <= kViewShoulderConfidenceDeltaThreshold) frontEvidence++;
    if (noseOffset <= kViewNoseOffsetThreshold) frontEvidence++;

    if (frontEvidence >= 2 && sideEvidence == 0) return CurlCameraView.front;
    if (sideEvidence >= 2) return _determineSide(ls, rs, nose);
    return CurlCameraView.unknown; // ambiguous — cast no vote
  }

  CurlCameraView _determineSide(
    dynamic ls, // PoseLandmark leftShoulder
    dynamic rs, // PoseLandmark rightShoulder
    dynamic nose, // PoseLandmark? nose
  ) {
    // Higher confidence = near-side shoulder = the one facing the camera.
    if (ls.confidence > rs.confidence) return CurlCameraView.sideLeft;
    if (rs.confidence > ls.confidence) return CurlCameraView.sideRight;
    // Tie-break: near shoulder is closest to nose in X.
    if (nose != null) {
      return (nose.x - ls.x).abs() < (nose.x - rs.x).abs()
          ? CurlCameraView.sideLeft
          : CurlCameraView.sideRight;
    }
    return CurlCameraView.front; // safe fallback
  }

  void _tryLock() {
    final recent = _frameVotes.length > kViewDetectionFrames
        ? _frameVotes.sublist(_frameVotes.length - kViewDetectionFrames)
        : List<CurlCameraView>.from(_frameVotes);

    final counts = <CurlCameraView, int>{};
    for (final v in recent) {
      counts[v] = (counts[v] ?? 0) + 1;
    }

    CurlCameraView? winner;
    int winnerCount = 0;
    for (final e in counts.entries) {
      if (e.value > winnerCount) {
        winnerCount = e.value;
        winner = e.key;
      }
    }
    if (winner != null && winnerCount >= kViewDetectionConsensusFrames) {
      _lockedView = winner;
      _isLocked = true;
    }
  }
}
