import '../core/types.dart';
import '../models/pose_result.dart';
import 'form_analyzer_base.dart';

/// Per-frame input handed to [ExerciseStrategy.tick].
///
/// All debounce / stuck-state gating happens in [RepCounter] before the
/// strategy runs, so strategies always receive a valid smoothed angle and
/// a non-null [now]. Strategies are responsible only for the FSM edges.
class StrategyFrameInput {
  final PoseResult pose;
  final double smoothedAngle;
  final DateTime now;
  final RepState state;

  /// Rep index within the current set (pre-increment view). Strategies use
  /// this for provider lookups (curl uses it to scope thresholds).
  final int repIndexInSet;

  const StrategyFrameInput({
    required this.pose,
    required this.smoothedAngle,
    required this.now,
    required this.state,
    required this.repIndexInSet,
  });
}

/// Per-frame output of [ExerciseStrategy.tick].
///
/// [repCommitted] is true exactly once per successful rep (on the committing
/// frame). [RepCounter] increments its rep count iff this flag is set, so
/// strategies must never emit it speculatively.
class StrategyFrameOutput {
  final RepState nextState;
  final bool repCommitted;
  final List<FormError> formErrors;

  const StrategyFrameOutput({
    required this.nextState,
    required this.repCommitted,
    required this.formErrors,
  });
}

/// Per-exercise FSM + form analyzer encapsulation.
///
/// Each strategy owns its exercise-specific fields (squat: long-femur
/// detection, prev hip Y; curl: view lock, bilateral angles, etc.) — none of
/// that state lives in [RepCounter].
///
/// Lifecycle:
///   computePrimaryAngle(pose)  — per frame, before the debounce gate.
///   tick(input)                — per frame, after the gate. Returns the
///                                next state and, optionally, rep-commit.
///   updateSetupView(pose)      — during SETUP_CHECK / COUNTDOWN only
///                                (curl-only; others are no-ops).
///   onNextSet() / onReset()    — called by RepCounter.nextSet / .reset.
abstract class ExerciseStrategy {
  ExerciseType get exercise;

  FormAnalyzerBase get formAnalyzer;

  /// Landmark indices the strategy relies on. Used by the widget's setup
  /// watchdog — if any required landmark is missing, setupCheck fails.
  List<int> get requiredLandmarkIndices;

  /// Compute the primary tracking angle (curl: elbow, squat: knee, push-up:
  /// elbow). Returns null when required landmarks are missing.
  double? computePrimaryAngle(PoseResult pose);

  /// Advance the FSM one frame. [input.state] is the strategy's current
  /// state; the returned [StrategyFrameOutput.nextState] is authoritative.
  StrategyFrameOutput tick(StrategyFrameInput input);

  /// Curl-only: update view detection during SETUP_CHECK / COUNTDOWN.
  /// Default implementation returns [CurlCameraView.unknown] — override in
  /// `CurlStrategy` only.
  CurlCameraView updateSetupView(PoseResult pose) => CurlCameraView.unknown;

  /// Called at set rollover. Reset per-rep / per-set state; session-scoped
  /// state (e.g. squat long-femur detection) survives across sets.
  void onNextSet();

  /// Called at hard reset. Restore first-use state entirely.
  void onReset();
}
