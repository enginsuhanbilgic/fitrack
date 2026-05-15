import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/squat_form_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import '../form_analyzer_base.dart';

/// Form analyzer for squat — research-grounded rulebook (Squat Master Rebuild).
///
/// Active frame-level errors (evaluated during DESCENDING + BOTTOM):
///   - `excessiveForwardLean`: signed trunk-from-vertical exceeds the
///     variant-specific threshold (45° BW, 50° HBBS, +5° if long-femur).
///     Backward lean (negative signed angle) does NOT fire — preventing
///     false positives for users who lean back as they squat.
///   - `heelLift`: `(foot_index_y − heel_y) / leg_len_px > 0.03`
///     (heel rises above forefoot in screen coords).
///   - `forwardKneeShift`: `(knee_x − ankle_x) / femur_len_px > 0.30`.
///     INFORMATIONAL — emitted to drive the on-screen highlight, but the
///     view-model's TTS path filters it out. No quality penalty.
///
/// Rep-boundary error (consumed once at rep commit):
///   - `squatDepth`: rep completed without reaching `effectiveBottomAngle`.
///
/// Per-rep quality score (mirrors curl multiplicative deduction model):
///   - Depth factor: `0.5 + 0.5 * ((180−minAngle)/(180−effectiveBottom))`
///   - Lean: up to `kQualitySquatLeanMaxDeduction` (0.20), proportional
///   - Heel lift: up to `kQualitySquatHeelLiftMaxDeduction` (0.10)
///   - Knee shift: intentionally excluded (informational only)
///
/// Camera-side selection: per frame, picks left vs. right based on
/// average hip+knee+ankle visibility. The two sides emit asymmetric
/// signals during a side-on recording — picking the high-visibility
/// side avoids flickering between low-confidence false-positives.
class SquatFormAnalyzer extends FormAnalyzerBase {
  SquatFormAnalyzer({
    required this.variant,
    required this.longFemurLifter,
    SquatFormThresholds formThresholds = SquatFormThresholds.defaults,
  }) : _formThresholds = formThresholds,
       _leanWarnDeg = formThresholds.leanWarnFor(
         variant,
         longFemur: longFemurLifter,
       );

  final SquatVariant variant;

  /// "Tall lifter" Settings toggle. Orthogonal to the auto-detected
  /// long-femur flag in `SquatStrategy` (which relaxes BOTTOM angle, not
  /// the lean threshold). The two never stack on the same threshold.
  final bool longFemurLifter;

  final SquatFormThresholds _formThresholds;

  /// Active lean threshold (variant-specific + optional +5° boost).
  /// Frozen at construction so a mid-session Settings change cannot affect
  /// an in-flight workout (snapshot-on-construction, plan flow-decision #2).
  final double _leanWarnDeg;

  // ── Per-rep extremes (all reset by `consumeCompletionErrorsWithDepth`) ──
  double? _minKneeAngle;
  double? _maxLeanDeg;
  double? _maxKneeShiftRatio;
  double? _maxHeelLiftRatio;

  // ── Hip-lead detection (per-rep) ────────────────────────────
  /// True between `onAscendingStart` and `onAscendingEnd`. Gates per-frame
  /// hip/shoulder Y appending — `evaluate()` does not accumulate during
  /// DESCENDING / BOTTOM so the velocity buffer is purely ASCENDING.
  bool _ascendingPhaseActive = false;

  /// Per-frame hip + shoulder Y samples accumulated during the ASCENDING
  /// phase. Cleared at `onDescendingStart` and again at rep commit. Records
  /// are taken from the higher-visibility camera side picked by
  /// `_pickCameraSide` — same side selection rule as the rest of the
  /// analyzer for consistency.
  final List<({double hipY, double shoulderY})> _ascendingFrames = [];

  /// Set by `onAscendingEnd` when the hip-lead check fires. Drained into
  /// `consumeCompletionErrorsWithDepth`'s return set on the next call.
  bool _lastRepHipLeadFired = false;

  /// Most recent hip-lead ratio (`mean(v_y_hip) / mean(v_y_shoulder)` over
  /// the evaluation window). Null until the check has run at least once
  /// AND the window had ≥4 valid velocity pairs. Exposed for telemetry.
  double? _lastRepHipLeadRatio;

  /// Mean hip/shoulder screen-Y velocity recorded during the last
  /// `onAscendingEnd`. Stored separately from the ratio so a
  /// sign-convention test can pin the SIGN of each velocity component
  /// independently — a regression that flipped the velocity formula
  /// `-(y[i] − y[i-1])` to `(y[i] − y[i-1])` is invisible in the ratio
  /// (both flip; signs cancel) but visible here.
  double? _lastRepHipMeanVelocity;
  double? _lastRepShoulderMeanVelocity;

  // ── Last-rep outputs (read by SquatStrategy after rep commit) ──
  double? _lastRepQuality;
  double? _lastRepLeanDeg;
  double? _lastRepKneeShiftRatio;
  double? _lastRepHeelLiftRatio;

  /// Active lean threshold (deg) for the lifetime of this analyzer.
  double get leanWarnDeg => _leanWarnDeg;

  /// Most recently committed rep's quality score (0.0–1.0). Null until
  /// the first rep is committed.
  double? get lastRepQuality => _lastRepQuality;

  /// Most recent peak-lean reading (deg). Null until first commit.
  double? get lastRepLeanDeg => _lastRepLeanDeg;

  /// Most recent peak knee-shift ratio. Null until first commit.
  double? get lastRepKneeShiftRatio => _lastRepKneeShiftRatio;

  /// Most recent peak heel-lift ratio. Null until first commit.
  double? get lastRepHeelLiftRatio => _lastRepHeelLiftRatio;

  /// Most recent hip-lead ratio (`mean(v_y_hip) / mean(v_y_shoulder)` over
  /// the first 30% of ASCENDING). Null when the check hasn't run yet OR
  /// the rep was skipped (fewer than `kHipLeadMinAscendingFrames` raw
  /// frames OR <4 valid velocity pairs after the stationary-shoulder
  /// filter). Surfaced for telemetry — `consumeCompletionErrorsWithDepth`
  /// drains it, but the host reads this getter for the `squat.hip_lead`
  /// log line.
  double? get lastRepHipLeadRatio => _lastRepHipLeadRatio;

  /// Mean per-frame screen-Y velocity of the hip over the evaluation
  /// window (sign convention: positive = rising). Exposed so tests can
  /// lock the screen-Y inversion contract: a sign flip in the velocity
  /// formula would not change `lastRepHipLeadRatio` (same flip applied
  /// to both numerator and denominator), but it WOULD invert this
  /// value. Null in the same cases as [lastRepHipLeadRatio].
  double? get lastRepHipMeanVelocity => _lastRepHipMeanVelocity;

  /// Mean per-frame screen-Y velocity of the shoulder. Same lifecycle
  /// and sign convention as [lastRepHipMeanVelocity].
  double? get lastRepShoulderMeanVelocity => _lastRepShoulderMeanVelocity;

  /// Number of raw frames accumulated during the most recent ASCENDING
  /// window. Reset by `onDescendingStart` (the start of the next rep), so
  /// the host has the full window's count between commit and the next
  /// IDLE → DESCENDING transition. Exposed for the `squat.hip_lead`
  /// telemetry's `ascending_frame_count` field.
  int get ascendingFrameCount => _ascendingFrames.length;

  /// Call at IDLE → DESCENDING. Resets per-rep extremes; preserves the
  /// `_lastRep*` outputs so the strategy can still read the previous rep's
  /// quality between reps.
  @override
  void onRepStart(PoseResult startSnapshot) {
    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    onDescendingStart();
  }

  /// Per-rep state for hip-lead. Called at IDLE → DESCENDING in addition
  /// to `onRepStart` — mirrors curl's `onRepStart` shape with an extra
  /// hook so the strategy can wire the lifecycle explicitly. Resets the
  /// hip-lead frame buffer + last-rep flags. Safe to call multiple times.
  void onDescendingStart() {
    _ascendingFrames.clear();
    _ascendingPhaseActive = false;
    _lastRepHipLeadFired = false;
    _lastRepHipLeadRatio = null;
    _lastRepHipMeanVelocity = null;
    _lastRepShoulderMeanVelocity = null;
  }

  /// Call at BOTTOM → ASCENDING. Enables per-frame hip+shoulder Y
  /// accumulation inside `evaluate()`.
  void onAscendingStart() {
    _ascendingPhaseActive = true;
  }

  /// Call at ASCENDING → IDLE (rep commit) BEFORE
  /// `consumeCompletionErrorsWithDepth(...)`. Evaluates the hip-lead
  /// ratio over the first [kHipLeadAscendingWindowFraction] of the
  /// collected frames; sets `_lastRepHipLeadFired` / `_lastRepHipLeadRatio`
  /// if the threshold is exceeded.
  ///
  /// Sign convention: in screen coordinates Y=0 is at the top, so
  /// "moving up" means `y` *decreases*. Velocity is computed as
  /// `-(y[i] − y[i-1])` so ascending produces POSITIVE values. A clean
  /// rep where hip and shoulder rise in lock-step yields ratio ≈ 1.0;
  /// a hip-lead rep yields ratio > 1.4.
  void onAscendingEnd() {
    _ascendingPhaseActive = false;
    final frames = _ascendingFrames;
    if (frames.length < kHipLeadMinAscendingFrames) return;

    final windowSize = math.max(
      kHipLeadMinAscendingFrames,
      (frames.length * kHipLeadAscendingWindowFraction).round(),
    );
    final clipped = windowSize > frames.length ? frames.length : windowSize;

    // Pairwise velocity over the window. Sign-inverted so screen-Y's
    // top-is-zero convention produces positive values during ascent.
    final hipVels = <double>[];
    final shoulderVels = <double>[];
    for (var i = 1; i < clipped; i++) {
      final dHip = -(frames[i].hipY - frames[i - 1].hipY);
      final dShoulder = -(frames[i].shoulderY - frames[i - 1].shoulderY);
      // Filter out frames where the shoulder is briefly stationary —
      // avoids div-by-zero noise on the ratio. The hip's own velocity
      // is unfiltered so a paused-shoulder hip-rising frame doesn't
      // drop out of the hip mean as well.
      if (dShoulder.abs() < 1e-6) continue;
      hipVels.add(dHip);
      shoulderVels.add(dShoulder);
    }

    // Fail-open below the minimum valid-pair count. A noisy 30%-of-rep
    // window where the shoulder was stationary for most frames doesn't
    // carry enough signal to grade — better to silently skip than to
    // false-fire on the few non-stationary samples.
    if (hipVels.length < 4) return;

    final meanHip = hipVels.reduce((a, b) => a + b) / hipVels.length;
    final meanShoulder =
        shoulderVels.reduce((a, b) => a + b) / shoulderVels.length;
    _lastRepHipMeanVelocity = meanHip;
    _lastRepShoulderMeanVelocity = meanShoulder;
    if (meanShoulder.abs() < 1e-6) return;
    final ratio = meanHip / meanShoulder;
    _lastRepHipLeadRatio = ratio;
    if (ratio > kHipLeadVelocityRatio) {
      _lastRepHipLeadFired = true;
    }
  }

  /// Track the lowest-knee-angle of the current rep. Called by
  /// `SquatStrategy` per frame during DESCENDING + BOTTOM.
  void trackAngle(double kneeAngle) {
    if (_minKneeAngle == null || kneeAngle < _minKneeAngle!) {
      _minKneeAngle = kneeAngle;
    }
  }

  /// Frame-level evaluation. Updates per-rep extremes and returns the set
  /// of frame-active errors.
  ///
  /// `forwardKneeShift` is intentionally surfaced here so the view-model
  /// can drive the visual highlight; the TTS path filters it out.
  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];

    final side = _pickCameraSide(current);
    if (side == null) return errors;

    // Hip-lead per-frame accumulation. Only active between
    // `onAscendingStart` and `onAscendingEnd` — frames during DESCENDING
    // and BOTTOM are deliberately excluded because the velocity signal
    // we care about is the hip-vs-shoulder rise rate at the start of the
    // ascent. Uses the same camera-side selection rule as the rest of
    // the analyzer so a confidence flicker doesn't pull samples from
    // the off-camera arm into the buffer.
    if (_ascendingPhaseActive) {
      final hip = current.landmark(
        side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
        minConfidence: kMinLandmarkConfidence,
      );
      final shoulder = current.landmark(
        side == ExerciseSide.left ? LM.leftShoulder : LM.rightShoulder,
        minConfidence: kMinLandmarkConfidence,
      );
      if (hip != null && shoulder != null) {
        _ascendingFrames.add((hipY: hip.y, shoulderY: shoulder.y));
      }
    }

    // Lean — signed; positive = forward, negative = backward.
    //
    // 2026-05-15: backward lean is now tracked AND cued. Pre-2026-05-15
    // `_signedLeanDeg` returned negative values for backward lean but the
    // analyzer filtered `lean > 0` at both the tracking site and the cue
    // site — erasing lumbar-hyperextension risk along with benign
    // counterbalance lean. Backward lean fires when `lean < -kSquatBackwardLeanWarnDeg`.
    final lean = _signedLeanDeg(current, side);
    if (lean != null) {
      // Track magnitude of the WORSE-direction lean for the per-rep peak.
      // Stored as a positive magnitude so `_lastRepLeanDeg` consumers see
      // a single number regardless of direction; direction is implied by
      // which FormError was emitted during the rep.
      final absLean = lean.abs();
      if (_maxLeanDeg == null || absLean > _maxLeanDeg!) {
        _maxLeanDeg = absLean;
      }
      if (lean > _leanWarnDeg) {
        errors.add(FormError.excessiveForwardLean);
      } else if (lean < -kSquatBackwardLeanWarnDeg) {
        errors.add(FormError.excessiveBackwardLean);
      }
    }

    // Knee shift — informational. Always non-negative.
    final kneeShift = _kneeShiftRatio(current, side);
    if (kneeShift != null) {
      if (_maxKneeShiftRatio == null || kneeShift > _maxKneeShiftRatio!) {
        _maxKneeShiftRatio = kneeShift;
      }
      if (kneeShift > _formThresholds.kneeShiftWarnRatio) {
        errors.add(FormError.forwardKneeShift);
      }
    }

    // Heel lift — non-negative ratio; fires when heel rises above forefoot.
    final heelLift = _heelLiftRatio(current, side);
    if (heelLift != null) {
      if (_maxHeelLiftRatio == null || heelLift > _maxHeelLiftRatio!) {
        _maxHeelLiftRatio = heelLift;
      }
      if (heelLift > _formThresholds.heelLiftWarnRatio) {
        errors.add(FormError.heelLift);
      }
    }

    return errors;
  }

  /// Base-contract stub. Squat completion requires the effective bottom
  /// angle (long-femur adaptation), so callers must use
  /// [consumeCompletionErrorsWithDepth] instead.
  @override
  List<FormError> consumeCompletionErrors() {
    throw UnsupportedError(
      'SquatFormAnalyzer requires effectiveBottomAngle — '
      'call consumeCompletionErrorsWithDepth instead.',
    );
  }

  /// Rep-boundary evaluation — called by `SquatStrategy` at rep commit.
  /// Computes the per-rep quality score, snapshots it for the strategy
  /// to read, then resets the per-rep extremes.
  ///
  /// IMPORTANT: callers must invoke `onAscendingEnd()` BEFORE this so the
  /// hip-lead check has populated `_lastRepHipLeadFired` /
  /// `_lastRepHipLeadRatio`. The quality score also reads
  /// `_lastRepHipLeadRatio`, so the ordering is load-bearing.
  List<FormError> consumeCompletionErrorsWithDepth(
    double effectiveBottomAngle,
  ) {
    final errors = <FormError>[];
    if (_minKneeAngle != null && _minKneeAngle! >= effectiveBottomAngle) {
      errors.add(FormError.squatDepth);
    }
    if (_lastRepHipLeadFired) {
      errors.add(FormError.hipLead);
    }

    _lastRepQuality = _computeQualityScore(
      effectiveBottomAngle: effectiveBottomAngle,
    );
    _lastRepLeanDeg = _maxLeanDeg;
    _lastRepKneeShiftRatio = _maxKneeShiftRatio;
    _lastRepHeelLiftRatio = _maxHeelLiftRatio;

    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    // `_ascendingFrames` is cleared at the NEXT `onDescendingStart` so a
    // test that inspects mid-rep state can still read the buffer
    // post-commit. `_lastRepHipLead*` fields drain the same way.
    return errors;
  }

  @override
  void reset() {
    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
    _lastRepQuality = null;
    _lastRepLeanDeg = null;
    _lastRepKneeShiftRatio = null;
    _lastRepHeelLiftRatio = null;
    _ascendingPhaseActive = false;
    _ascendingFrames.clear();
    _lastRepHipLeadFired = false;
    _lastRepHipLeadRatio = null;
    _lastRepHipMeanVelocity = null;
    _lastRepShoulderMeanVelocity = null;
  }

  // ── Internals ────────────────────────────────────────────

  /// Picks the camera-side (left or right) with higher average visibility
  /// across hip + knee + ankle landmarks. Returns null if neither side has
  /// the required landmarks above the confidence gate.
  ExerciseSide? _pickCameraSide(PoseResult p) {
    final leftAvg = _sideAvgVisibility(p, isLeft: true);
    final rightAvg = _sideAvgVisibility(p, isLeft: false);
    if (leftAvg == null && rightAvg == null) return null;
    if (leftAvg == null) return ExerciseSide.right;
    if (rightAvg == null) return ExerciseSide.left;
    return leftAvg >= rightAvg ? ExerciseSide.left : ExerciseSide.right;
  }

  double? _sideAvgVisibility(PoseResult p, {required bool isLeft}) {
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final knee = p.landmark(
      isLeft ? LM.leftKnee : LM.rightKnee,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || knee == null || ankle == null) return null;
    return (hip.confidence + knee.confidence + ankle.confidence) / 3.0;
  }

  /// Signed forward-lean angle (degrees). Positive = forward (hip ahead of
  /// shoulder along the camera's +x axis); negative = backward.
  ///
  /// `atan2(dx, dy)` is used so the magnitude matches the trunk's tilt
  /// from vertical regardless of how far apart the two landmarks are
  /// (purely angular — independent of body size in pixels).
  double? _signedLeanDeg(PoseResult p, ExerciseSide side) {
    final shoulder = p.landmark(
      side == ExerciseSide.left ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    if (shoulder == null || hip == null) return null;
    final dx = hip.x - shoulder.x;
    final dy = (hip.y - shoulder.y).abs();
    if (dy < 1e-6) return null;
    return math.atan2(dx, dy) * 180.0 / math.pi;
  }

  /// Forward knee shift ratio. Positive only — backward (knee behind
  /// ankle) is clamped to 0 since the cue would never fire there.
  double? _kneeShiftRatio(PoseResult p, ExerciseSide side) {
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final knee = p.landmark(
      side == ExerciseSide.left ? LM.leftKnee : LM.rightKnee,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || knee == null || ankle == null) return null;
    final femurLen = _euclidean(hip, knee);
    if (femurLen < 1e-6) return null;
    final shift = math.max(0.0, knee.x - ankle.x);
    return shift / femurLen;
  }

  /// Heel lift ratio. Positive when the heel rises above the forefoot
  /// (ankle stays grounded but `foot_index` drops below `heel`).
  ///
  /// In screen coordinates Y=0 is top, so a heel rising means `heel.y`
  /// becomes smaller (more negative offset) than `foot_index.y`. We
  /// measure `(foot_index.y - heel.y)` and clamp at 0; non-zero means
  /// the heel is above the forefoot in screen space.
  double? _heelLiftRatio(PoseResult p, ExerciseSide side) {
    final hip = p.landmark(
      side == ExerciseSide.left ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      side == ExerciseSide.left ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    final heel = p.landmark(
      side == ExerciseSide.left ? LM.leftHeel : LM.rightHeel,
      minConfidence: kMinLandmarkConfidence,
    );
    final foot = p.landmark(
      side == ExerciseSide.left ? LM.leftFootIndex : LM.rightFootIndex,
      minConfidence: kMinLandmarkConfidence,
    );
    if (hip == null || ankle == null || heel == null || foot == null) {
      return null;
    }
    // Leg length = hip → ankle (sagittal-plane proxy, robust to camera
    // distance). 1e-6 guard against degenerate poses.
    final legLen = _euclidean(hip, ankle);
    if (legLen < 1e-6) return null;
    final lift = math.max(0.0, foot.y - heel.y);
    return lift / legLen;
  }

  double _euclidean(PoseLandmark a, PoseLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Per-rep quality score (0.0–1.0). Multiplicative composition of:
  ///   - Depth factor (1.0 if reached effective bottom; tapers linearly).
  ///   - Lean penalty (proportional, capped at `kQualitySquatLeanMaxDeduction`).
  ///   - Heel-lift penalty (proportional, capped at `kQualitySquatHeelLiftMaxDeduction`).
  ///
  /// Knee-shift is excluded by design (informational only). Backward lean
  /// is excluded because `_maxLeanDeg` is only updated for positive lean.
  double _computeQualityScore({required double effectiveBottomAngle}) {
    var score = 1.0;

    // Depth factor — multiplicative. Gives full credit when minAngle <=
    // effectiveBottom; otherwise interpolates linearly so a half-rep gets
    // ~0.5 weight.
    final minAngle = _minKneeAngle ?? 180.0;
    final double depthFactor;
    if (minAngle <= effectiveBottomAngle) {
      depthFactor = 1.0;
    } else {
      final span = 180.0 - effectiveBottomAngle;
      if (span <= 1e-6) {
        depthFactor = 1.0;
      } else {
        final progress = ((180.0 - minAngle) / span).clamp(0.0, 1.0);
        depthFactor = 0.5 + 0.5 * progress;
      }
    }
    score *= depthFactor;

    // Lean — proportional. Severity 1.0 reached at lean = warn + 30°.
    final maxLean = _maxLeanDeg;
    if (maxLean != null && maxLean > _leanWarnDeg) {
      final severity = ((maxLean - _leanWarnDeg) / 30.0).clamp(0.0, 1.0);
      score *= 1.0 - severity * kQualitySquatLeanMaxDeduction;
    }

    // Heel lift — proportional. Severity 1.0 reached at ratio 0.05
    // (~67% above the warning floor).
    final maxHeel = _maxHeelLiftRatio;
    if (maxHeel != null && maxHeel > _formThresholds.heelLiftWarnRatio) {
      final severity = (maxHeel / 0.05).clamp(0.0, 1.0);
      score *= 1.0 - severity * kQualitySquatHeelLiftMaxDeduction;
    }

    // Hip-lead — proportional. Applied AFTER lean and heel-lift per plan
    // ordering (multiplicative composition, so the order doesn't change
    // the numerical outcome — but documents the design intent). Severity
    // 1.0 reached at ratio = warn + 0.6 (i.e. 2.0); ratio at threshold
    // (1.4) yields zero deduction so a borderline-fail rep doesn't
    // double-count between the cue and the quality score.
    final hipLeadRatio = _lastRepHipLeadRatio;
    if (hipLeadRatio != null && hipLeadRatio > kHipLeadVelocityRatio) {
      final severity = ((hipLeadRatio - kHipLeadVelocityRatio) / 0.6).clamp(
        0.0,
        1.0,
      );
      score *= 1.0 - severity * kQualitySquatHipLeadMaxDeduction;
    }

    return score.clamp(0.0, 1.0);
  }
}
