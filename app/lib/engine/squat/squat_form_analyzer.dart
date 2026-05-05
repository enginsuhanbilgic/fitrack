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

  /// Call at IDLE → DESCENDING. Resets per-rep extremes; preserves the
  /// `_lastRep*` outputs so the strategy can still read the previous rep's
  /// quality between reps.
  @override
  void onRepStart(PoseResult startSnapshot) {
    _minKneeAngle = null;
    _maxLeanDeg = null;
    _maxKneeShiftRatio = null;
    _maxHeelLiftRatio = null;
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

    // Lean — signed; positive = forward, negative = backward.
    final lean = _signedLeanDeg(current, side);
    if (lean != null) {
      // Track magnitude of forward lean only — backward lean doesn't
      // contribute to the peak (and doesn't fire the error).
      if (lean > 0 && (_maxLeanDeg == null || lean > _maxLeanDeg!)) {
        _maxLeanDeg = lean;
      }
      if (lean > _leanWarnDeg) {
        errors.add(FormError.excessiveForwardLean);
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
  List<FormError> consumeCompletionErrorsWithDepth(
    double effectiveBottomAngle,
  ) {
    final errors = <FormError>[];
    if (_minKneeAngle != null && _minKneeAngle! >= effectiveBottomAngle) {
      errors.add(FormError.squatDepth);
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

    return score.clamp(0.0, 1.0);
  }
}
