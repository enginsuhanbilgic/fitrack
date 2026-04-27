import 'dart:math' as math;

import '../../core/constants.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../one_euro_filter.dart';

/// Result of a single corroborator update.
///
/// `verticalZ` and `scaleZ` are null until the baseline window has
/// closed. `landmarksAvailable` is false on any frame where nose,
/// leftEar, or rightEar fall below [kHeadCorroborationMinVisibility]
/// — callers should treat this as fail-open (do not veto a sway
/// warning when we cannot trust the head signal).
class HeadCorroborationResult {
  const HeadCorroborationResult({
    required this.verticalZ,
    required this.scaleZ,
    required this.baselineReady,
    required this.landmarksAvailable,
  });

  /// Z-scored vertical head position relative to baseline.
  /// Normalized by the baseline torso length so it survives different
  /// camera distances. Null until baseline ready.
  final double? verticalZ;

  /// Z-scored inter-ear distance relative to baseline. Acts as a 1/Z
  /// scale proxy — when the lifter leans toward the camera, the head
  /// grows in apparent size, ears move apart in image space. Null
  /// until baseline ready.
  final double? scaleZ;

  /// True once the baseline window has been collected and z-scoring
  /// is active. False during warm-up.
  final bool baselineReady;

  /// True when nose + both ears were visible above
  /// [kHeadCorroborationMinVisibility] on this frame. False means the
  /// frame was rejected and no state was advanced — the analyzer
  /// should fail open (not veto) when this is false.
  final bool landmarksAvailable;
}

/// Veto layer for `FormError.depthSwing`.
///
/// **Why this exists:** ML Kit's 2D pose model assigns each landmark
/// an `inFrameLikelihood` confidence score, but that score does NOT
/// drop when a body part is occluded by another body part — the model
/// interpolates from skeleton priors and stays confident. So when the
/// curling arm passes in front of the torso, the shoulder and hip
/// (x, y) coordinates *drift* without their confidences ever falling.
/// The `SagittalSwayDetector` consumes that drift as real motion and
/// fires a depth-swing warning even though the user has not moved.
///
/// **Why the head is the right witness:** the nose and ears sit
/// physically above the shoulders, well outside the arm-over-torso
/// occlusion zone. A *real* sagittal sway moves the whole spine —
/// including the head — so the head's vertical position and apparent
/// scale will both shift. An *artifact* sway (arm shadow) leaves the
/// head untouched. Comparing the two signals lets us veto false
/// positives without weakening real-sway detection.
///
/// **Two signals, weighted:**
///   - `nose.y` — direct vertical head position. Dominant signal
///     (`kHeadVerticalWeight = 0.7`) because forward/back rocking in
///     a roughly-fixed camera frame translates almost entirely into
///     vertical nose motion.
///   - inter-ear distance — 1/Z scale proxy. Secondary signal
///     (`kHeadScaleWeight = 0.3`) because head turn (yaw) also
///     changes ear distance and we don't want to over-weight it.
///
/// **Pipeline mirrors `SagittalSwayDetector`:** 1€-filtered features,
/// baseline window of [kHeadBaselineMinFrames] neutral-pose samples
/// to establish (μ, σ), slow EMA σ adaptation hard-capped at
/// [kHeadSigmaDriftCap] × initial σ to prevent fatigue-induced drift
/// from swallowing real head motion. The `nose.y` z-score is
/// normalized by baseline torso length so it stays dimensionless
/// across camera distances.
///
/// **Fail-open contract:** when nose or either ear is below
/// [kHeadCorroborationMinVisibility], or when the baseline has not
/// yet closed, the corroborator returns a result that callers should
/// interpret as "no veto" — the original sway detector's verdict
/// stands. This means adding the corroborator can only *suppress*
/// false positives, never introduce false negatives.
class HeadStabilityCorroborator {
  // ── Filters (one per signal) ────────────────────────────
  final OneEuroFilter _noseYFilter = OneEuroFilter();
  final OneEuroFilter _earDistFilter = OneEuroFilter();

  // ── Baseline accumulators ───────────────────────────────
  // We collect raw `nose.y` and inter-ear distance during baseline,
  // then close out (μ, σ) and capture a baseline torso length to
  // normalize the vertical signal so the z-score is dimensionless.
  final List<double> _baselineNoseY = [];
  final List<double> _baselineEarDist = [];
  final List<double> _baselineTorsoLen = [];

  double _muNoseY = 0, _muEarDist = 0;
  double _sigNoseY = 1, _sigEarDist = 1;
  double _initialSigNoseY = 1, _initialSigEarDist = 1;
  double _baselineTorsoLenMean = 1.0;
  bool _baselineReady = false;

  /// Reset all state — call on view change, session reset, or whenever
  /// a new baseline must be collected. Filters are reset, baseline
  /// window re-opens.
  void reset() {
    _noseYFilter.reset();
    _earDistFilter.reset();
    _baselineNoseY.clear();
    _baselineEarDist.clear();
    _baselineTorsoLen.clear();
    _muNoseY = 0;
    _muEarDist = 0;
    _sigNoseY = 1;
    _sigEarDist = 1;
    _initialSigNoseY = 1;
    _initialSigEarDist = 1;
    _baselineTorsoLenMean = 1.0;
    _baselineReady = false;
  }

  /// True once the baseline window has filled and z-scoring is active.
  bool get baselineReady => _baselineReady;

  /// Ingest a frame and return the current head-stability signals.
  ///
  /// [now] is the wall-clock instant of this pose sample (use the same
  /// `DateTime.now()` source as the analyzer so the 1€ filter sees a
  /// monotonic time). [allowBaseline] is true when the host knows the
  /// user is in a neutral-pose state (FSM IDLE / between reps) — only
  /// baseline-eligible frames feed (μ, σ). Mirrors the
  /// `SagittalSwayDetector.update` semantics exactly.
  HeadCorroborationResult update({
    required PoseResult pose,
    required DateTime now,
    required bool allowBaseline,
  }) {
    final features = _computeFeatures(pose);
    if (features == null) {
      // Visibility / geometry gate failed — surface "no head signal"
      // and do not advance state. Caller treats as fail-open (no veto).
      return HeadCorroborationResult(
        verticalZ: null,
        scaleZ: null,
        baselineReady: _baselineReady,
        landmarksAvailable: false,
      );
    }

    final t = now.microsecondsSinceEpoch / 1e6;

    // 1€-filter each raw signal.
    final noseY = _noseYFilter.filter(features.noseY, t);
    final earDist = _earDistFilter.filter(features.earDist, t);

    // Baseline collection — only when host marks the frame neutral.
    if (allowBaseline && !_baselineReady) {
      _baselineNoseY.add(noseY);
      _baselineEarDist.add(earDist);
      _baselineTorsoLen.add(features.torsoLen);
      if (_baselineNoseY.length >= kHeadBaselineMinFrames) {
        _muNoseY = _mean(_baselineNoseY);
        _muEarDist = _mean(_baselineEarDist);
        _sigNoseY = _stddev(_baselineNoseY, _muNoseY);
        _sigEarDist = _stddev(_baselineEarDist, _muEarDist);
        _initialSigNoseY = _sigNoseY;
        _initialSigEarDist = _sigEarDist;
        _baselineTorsoLenMean = _mean(_baselineTorsoLen);
        // Floor torso length so a degenerate baseline doesn't divide
        // by ~0 and explode the vertical z-score.
        if (_baselineTorsoLenMean < 1e-3) _baselineTorsoLenMean = 1e-3;
        _baselineReady = true;
      }
      return HeadCorroborationResult(
        verticalZ: null,
        scaleZ: null,
        baselineReady: _baselineReady,
        landmarksAvailable: true,
      );
    }

    if (!_baselineReady) {
      // Baseline still warming, host marked frame ineligible — wait.
      return HeadCorroborationResult(
        verticalZ: null,
        scaleZ: null,
        baselineReady: false,
        landmarksAvailable: true,
      );
    }

    // Slow σ adaptation (only on baseline-eligible frames after warm-up)
    // with hard cap to prevent drift swallowing real head motion.
    if (allowBaseline) {
      _adaptSigma(noseY, earDist);
    }

    // Z-score each signal. Normalize the vertical signal by the
    // baseline torso length so it is dimensionless across camera
    // distances (a 5px nose drift means very different things at
    // arm's length vs. across the room).
    final verticalDelta = (noseY - _muNoseY) / _baselineTorsoLenMean;
    final scaleZ = (earDist - _muEarDist) / (_sigEarDist + 1e-6);
    // The vertical signal's σ is computed in raw image-space units
    // before normalization, so we must divide σ by the same torso
    // length to keep the z-score consistent with the raw delta.
    final verticalZ =
        verticalDelta / ((_sigNoseY / _baselineTorsoLenMean) + 1e-6);

    return HeadCorroborationResult(
      verticalZ: verticalZ,
      scaleZ: scaleZ,
      baselineReady: true,
      landmarksAvailable: true,
    );
  }

  // ── Internals ───────────────────────────────────────────

  /// Compute (nose.y, inter-ear distance, torso length) from a pose.
  /// Returns null when any required landmark is missing / below the
  /// visibility gate, or when the geometry is degenerate.
  _Features? _computeFeatures(PoseResult pose) {
    final nose = pose.landmark(
      LM.nose,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    final lEar = pose.landmark(
      LM.leftEar,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    final rEar = pose.landmark(
      LM.rightEar,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    if (nose == null || lEar == null || rEar == null) return null;

    // Torso length is needed only at baseline close, but we compute
    // it every frame so the baseline accumulator stays in lock-step
    // with the head signals. Use the same midpoint convention as
    // SagittalSwayDetector — average of L/R shoulder to average of
    // L/R hip. Required for normalization; if torso landmarks are
    // missing at baseline-collection time, we skip the frame.
    final ls = pose.landmark(
      LM.leftShoulder,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    final rs = pose.landmark(
      LM.rightShoulder,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    final lh = pose.landmark(
      LM.leftHip,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    final rh = pose.landmark(
      LM.rightHip,
      minConfidence: kHeadCorroborationMinVisibility,
    );
    if (ls == null || rs == null || lh == null || rh == null) return null;

    final shoulderMidY = (ls.y + rs.y) / 2;
    final hipMidY = (lh.y + rh.y) / 2;
    final torsoLen = (hipMidY - shoulderMidY).abs();
    if (torsoLen < 1e-4) return null;

    final earDist = _dist(lEar.x, lEar.y, rEar.x, rEar.y);
    if (earDist < 1e-4) return null;

    return _Features(noseY: nose.y, earDist: earDist, torsoLen: torsoLen);
  }

  void _adaptSigma(double noseY, double earDist) {
    // EMA-style σ tracking, then hard cap. Slow α (~0.02) so a single
    // off-frame can't expand the band materially. Mirrors the pattern
    // used in `SagittalSwayDetector._adaptSigma`.
    const alpha = 0.02;
    _sigNoseY = (1 - alpha) * _sigNoseY + alpha * (noseY - _muNoseY).abs();
    _sigEarDist =
        (1 - alpha) * _sigEarDist + alpha * (earDist - _muEarDist).abs();
    if (_sigNoseY > kHeadSigmaDriftCap * _initialSigNoseY) {
      _sigNoseY = kHeadSigmaDriftCap * _initialSigNoseY;
    }
    if (_sigEarDist > kHeadSigmaDriftCap * _initialSigEarDist) {
      _sigEarDist = kHeadSigmaDriftCap * _initialSigEarDist;
    }
  }

  static double _dist(double ax, double ay, double bx, double by) {
    final dx = ax - bx;
    final dy = ay - by;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _mean(List<double> xs) =>
      xs.fold(0.0, (a, b) => a + b) / xs.length;

  static double _stddev(List<double> xs, double mu) {
    if (xs.length < 2) return 1e-3;
    final v = xs.fold(0.0, (a, x) => a + (x - mu) * (x - mu)) / (xs.length - 1);
    final s = math.sqrt(v);
    // Floor σ so a perfectly still baseline doesn't divide by ~0.
    return s < 1e-3 ? 1e-3 : s;
  }
}

class _Features {
  const _Features({
    required this.noseY,
    required this.earDist,
    required this.torsoLen,
  });
  final double noseY;
  final double earDist;
  final double torsoLen;
}
