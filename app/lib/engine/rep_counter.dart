import '../core/constants.dart';
import '../core/types.dart';
import '../models/pose_result.dart';
import 'curl/curl_strategy.dart';
import 'exercise_strategy.dart';
import 'push_up/push_up_strategy.dart';
import 'squat/squat_strategy.dart';

// Typedefs are re-exported here so existing call sites keep importing them
// from `rep_counter.dart` unchanged.
export 'curl/curl_strategy.dart'
    show RomThresholdsProvider, CurlRepCommitCallback;

/// Snapshot returned after every frame — everything the UI needs.
class RepSnapshot {
  final int reps;
  final int sets;
  final RepState state;
  final double? jointAngle;
  final List<FormError> formErrors;
  final CurlCameraView detectedView;
  final double? lastRepQuality;
  final double? averageQuality;
  final List<double> repQualities;
  final bool fatigueDetected;
  final int eccentricTooFastCount;
  final Set<FormError> errorsTriggered;

  const RepSnapshot({
    required this.reps,
    required this.sets,
    required this.state,
    this.jointAngle,
    this.formErrors = const [],
    this.detectedView = CurlCameraView.unknown,
    this.lastRepQuality,
    this.averageQuality,
    this.repQualities = const [],
    this.fatigueDetected = false,
    this.eccentricTooFastCount = 0,
    this.errorsTriggered = const {},
  });
}

/// Multi-exercise rep counter. Dispatches to an [ExerciseStrategy] per
/// exercise; owns only the cross-cutting concerns:
///   - Angle smoothing (3-frame moving average).
///   - Debounce gate (`kStateDebounce`, invariant 1).
///   - Stuck-state watchdog (`kStuckStateLimit`, invariant 2).
///   - Rep / set counters.
///
/// Adding a new exercise is additive — write a new `ExerciseStrategy`,
/// register it in [_buildStrategy], and nothing else changes here.
class RepCounter {
  final ExerciseType exercise;
  final ExerciseSide side;

  late final ExerciseStrategy _strategy;

  RepState _state = RepState.idle;
  int _reps = 0;
  int _sets = 1;
  double? _lastAngle;
  List<FormError> _lastErrors = const [];

  DateTime? _lastTransitionTime;
  DateTime? _stateStartTime;

  final List<double> _angleBuffer = [];
  static const int _smoothWindow = 3;

  RepCounter({
    this.exercise = ExerciseType.bicepsCurl,
    this.side = ExerciseSide.both,
    RomThresholdsProvider? curlThresholdsProvider,
    CurlRepCommitCallback? onCurlRepCommit,
    List<Duration> curlHistoricalConcentricDurations = const [],
  }) {
    _strategy = _buildStrategy(
      exercise: exercise,
      side: side,
      curlThresholdsProvider: curlThresholdsProvider,
      onCurlRepCommit: onCurlRepCommit,
      curlHistoricalConcentricDurations: curlHistoricalConcentricDurations,
    );
  }

  static ExerciseStrategy _buildStrategy({
    required ExerciseType exercise,
    required ExerciseSide side,
    RomThresholdsProvider? curlThresholdsProvider,
    CurlRepCommitCallback? onCurlRepCommit,
    List<Duration> curlHistoricalConcentricDurations = const [],
  }) => switch (exercise) {
    ExerciseType.bicepsCurl => CurlStrategy(
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      historicalConcentricDurations: curlHistoricalConcentricDurations,
    ),
    ExerciseType.squat => SquatStrategy(),
    ExerciseType.pushUp => PushUpStrategy(),
  };

  RepSnapshot update(PoseResult result) {
    final now = DateTime.now();
    final angle = _strategy.computePrimaryAngle(result);
    _lastAngle = angle;

    if (angle == null) {
      return _snapshot();
    }

    _angleBuffer.add(angle);
    if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
    final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    // Stuck-state watchdog (invariant 2).
    if (_state != RepState.idle && _stateStartTime != null) {
      if (now.difference(_stateStartTime!) > kStuckStateLimit) {
        _resetToIdle();
        return _snapshot();
      }
    }

    // Debounce gate (invariant 1).
    if (_lastTransitionTime != null &&
        now.difference(_lastTransitionTime!) < kStateDebounce) {
      return _snapshot();
    }

    final output = _strategy.tick(
      StrategyFrameInput(
        pose: result,
        smoothedAngle: smoothed,
        now: now,
        state: _state,
        repIndexInSet: _reps,
      ),
    );

    _lastErrors = output.formErrors;

    if (output.repCommitted) {
      _reps++;
    }

    if (output.nextState != _state) {
      _state = output.nextState;
      _lastTransitionTime = now;
      _stateStartTime = now;
    }

    return _snapshot();
  }

  /// Call once per frame during SETUP_CHECK and COUNTDOWN (biceps curl only).
  /// Returns the current detected view; [CurlCameraView.unknown] until locked
  /// or when the active exercise is not biceps curl.
  CurlCameraView updateSetupView(PoseResult pose) =>
      _strategy.updateSetupView(pose);

  /// Start a new set — resets reps, keeps set count.
  void nextSet() {
    _sets++;
    _reps = 0;
    _angleBuffer.clear();
    _state = RepState.idle;
    _stateStartTime = null;
    _lastErrors = const [];
    _strategy.onNextSet();
  }

  /// Full reset.
  void reset() {
    _reps = 0;
    _sets = 1;
    _state = RepState.idle;
    _angleBuffer.clear();
    _stateStartTime = null;
    _lastTransitionTime = null;
    _lastErrors = const [];
    _lastAngle = null;
    _strategy.onReset();
  }

  // ── Internals ─────────────────────────────────────────────────────

  void _resetToIdle() {
    _state = RepState.idle;
    _stateStartTime = null;
  }

  RepSnapshot _snapshot() {
    // Surface curl-specific fields only when the active strategy is curl.
    // One-per-frame downcast — acceptable cost for cross-layer clarity.
    final strategy = _strategy;
    final isCurl = strategy is CurlStrategy;
    return RepSnapshot(
      reps: _reps,
      sets: _sets,
      state: _state,
      jointAngle: _lastAngle,
      formErrors: _lastErrors,
      detectedView: isCurl ? strategy.lockedView : CurlCameraView.unknown,
      lastRepQuality: isCurl ? strategy.formExtras.lastRepQuality : null,
      averageQuality: isCurl ? strategy.formExtras.averageQuality : null,
      repQualities: isCurl ? strategy.formExtras.repQualities : const [],
      fatigueDetected: isCurl ? strategy.formExtras.fatigueDetected : false,
      eccentricTooFastCount: isCurl
          ? strategy.formExtras.eccentricTooFastCount
          : 0,
      errorsTriggered: const {},
    );
  }
}
