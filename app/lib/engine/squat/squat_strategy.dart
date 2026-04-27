import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'squat_form_analyzer.dart';

/// Squat FSM encapsulated as a strategy.
///
/// Two scopes of state:
///   - **Per-rep** (cleared at every rep): `_minAngleThisRep`, `_prevHipY`.
///   - **Session** (survives `onNextSet`, cleared on `onReset`):
///     `_repMinAngles`, `_longFemurDetected`, `_effectiveBottomAngle`.
///
/// The session scope is load-bearing — long-femur classification needs
/// cumulative evidence across sets (mirrors original RepCounter behavior).
///
/// Constructor params (Squat Master Rebuild, 2026-04-25):
///   - `variant` — Bodyweight or Barbell back squat. Toggles the
///     analyzer's lean threshold (45° vs 50°).
///   - `longFemurLifter` — "Tall lifter" Settings toggle. Adds +5° to
///     the lean threshold inside the analyzer.
///
/// Long-femur orthogonality: the auto-detected `_longFemurDetected` flag
/// (this class) widens the BOTTOM gate from 90° → 100°. The
/// user-facing `longFemurLifter` toggle (analyzer) widens the lean
/// threshold by +5°. The two flags target different thresholds — they
/// never stack on the same one.
class SquatStrategy extends ExerciseStrategy {
  SquatStrategy({
    this.variant = SquatVariant.bodyweight,
    this.longFemurLifter = false,
  }) : _form = SquatFormAnalyzer(
         variant: variant,
         longFemurLifter: longFemurLifter,
       );

  final SquatVariant variant;
  final bool longFemurLifter;

  final SquatFormAnalyzer _form;

  // Per-rep.
  double? _prevHipY;
  double? _minAngleThisRep;

  // Session-scoped long-femur detection.
  final List<double> _repMinAngles = [];
  bool _longFemurDetected = false;
  double _effectiveBottomAngle = kSquatBottomAngle;

  @override
  ExerciseType get exercise => ExerciseType.squat;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(ExerciseType.squat).landmarkIndices;

  /// Current effective bottom angle — relaxed if long-femur auto-detected.
  /// Exposed primarily for tests and for the summary screen.
  double get effectiveBottomAngle => _effectiveBottomAngle;

  /// Quality score for the most recently committed rep. Null until the
  /// first rep commits in the current session.
  double? get lastRepQuality => _form.lastRepQuality;

  /// Most recent peak forward-lean (deg). Null until first commit.
  double? get lastRepLeanDeg => _form.lastRepLeanDeg;

  /// Most recent peak knee-shift ratio. Null until first commit.
  double? get lastRepKneeShiftRatio => _form.lastRepKneeShiftRatio;

  /// Most recent peak heel-lift ratio. Null until first commit.
  double? get lastRepHeelLiftRatio => _form.lastRepHeelLiftRatio;

  /// Active lean warning threshold (variant + tall-lifter boost). Useful
  /// for tests asserting orthogonality of long-femur signals.
  double get leanWarnDeg => _form.leanWarnDeg;

  @override
  double? computePrimaryAngle(PoseResult pose) {
    final leftAngle = angleDeg(
      pose.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftKnee, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
    );
    final rightAngle = angleDeg(
      pose.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightKnee, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightAnkle, minConfidence: kMinLandmarkConfidence),
    );
    if (leftAngle != null && rightAngle != null) {
      return (leftAngle + rightAngle) / 2.0;
    }
    return leftAngle ?? rightAngle;
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;
    final hipY = _computeHipY(pose);

    // Track minimum knee angle during active descent for long-femur detection.
    if (input.state == RepState.descending || input.state == RepState.bottom) {
      if (_minAngleThisRep == null || smoothed < _minAngleThisRep!) {
        _minAngleThisRep = smoothed;
      }
      _form.trackAngle(smoothed);
    }

    var nextState = input.state;
    var repCommitted = false;
    var errors = <FormError>[];

    // Frame-level form evaluation runs in all three active phases. Lean +
    // heel-lift + knee-shift express themselves throughout the descent,
    // not only on the way up — so we evaluate during DESCENDING + BOTTOM
    // + ASCENDING to catch the worst-frame in each metric.
    if (input.state == RepState.descending ||
        input.state == RepState.bottom ||
        input.state == RepState.ascending) {
      errors = _form.evaluate(pose, now: input.now);
    }

    switch (input.state) {
      case RepState.idle:
        if (smoothed < kSquatStartAngle) {
          nextState = RepState.descending;
          _form.onRepStart(pose);
        }
      case RepState.descending:
        if (smoothed < _effectiveBottomAngle) {
          nextState = RepState.bottom;
        } else if (smoothed > kSquatStartAngle) {
          nextState = RepState.idle;
          _resetPerRepState();
        }
      case RepState.bottom:
        // Transition to ascending only when hip is actually rising.
        // In screen coordinates Y=0 is top, so rising = Y decreasing.
        if (hipY != null && _prevHipY != null && hipY < _prevHipY!) {
          nextState = RepState.ascending;
        }
      case RepState.ascending:
        if (smoothed >= kSquatEndAngle) {
          final completionErrors = _form.consumeCompletionErrorsWithDepth(
            _effectiveBottomAngle,
          );
          errors = [...errors, ...completionErrors];
          _maybeUpdateLongFemur();
          repCommitted = true;
          nextState = RepState.idle;
          _resetPerRepState();
        }
      default:
        break;
    }

    _prevHipY = hipY;

    return StrategyFrameOutput(
      nextState: nextState,
      repCommitted: repCommitted,
      formErrors: errors,
    );
  }

  @override
  void onNextSet() {
    // Per-rep cleared; session-scoped long-femur state survives.
    _prevHipY = null;
    _minAngleThisRep = null;
    _form.reset();
  }

  @override
  void onReset() {
    _prevHipY = null;
    _minAngleThisRep = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _effectiveBottomAngle = kSquatBottomAngle;
    _form.reset();
  }

  // ── Internals ─────────────────────────────────────────────────────

  void _resetPerRepState() {
    _prevHipY = null;
    _minAngleThisRep = null;
  }

  /// Long-femur adaptation: if the user consistently bottoms between
  /// [kSquatBottomAngle] and [kLongFemurBottomAngle] for
  /// [kLongFemurDetectReps] consecutive reps, relax the bottom threshold.
  void _maybeUpdateLongFemur() {
    if (_longFemurDetected) return;
    if (_minAngleThisRep == null) return;

    _repMinAngles.add(_minAngleThisRep!);
    if (_repMinAngles.length < kLongFemurDetectReps) return;

    final allAbove90 = _repMinAngles.every((a) => a > kSquatBottomAngle);
    final allReached100 = _repMinAngles.every(
      (a) => a <= kLongFemurBottomAngle,
    );
    if (allAbove90 && allReached100) {
      _longFemurDetected = true;
      _effectiveBottomAngle = kLongFemurBottomAngle;
      // Log only in checked builds — keeps squat_strategy.dart pure-Dart
      // so the offline replay harness (tools/dataset_analysis/dart_replay)
      // can run without pulling in package:flutter.
      assert(() {
        // ignore: avoid_print
        print(
          '[SquatStrategy] Long-femur detected — relaxing BOTTOM to '
          '$kLongFemurBottomAngle°',
        );
        return true;
      }());
    }
  }

  double? _computeHipY(PoseResult r) {
    final left = r.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence);
    final right = r.landmark(
      LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    if (left != null && right != null) return (left.y + right.y) / 2.0;
    return left?.y ?? right?.y;
  }
}
