import '../core/constants.dart';
import '../core/types.dart';
import '../models/pose_result.dart';
import 'curl/curl_form_analyzer_extras.dart';
import 'curl/curl_strategy.dart';
import 'curl/dtw_scorer.dart';
import 'exercise_strategy.dart';
import 'push_up/push_up_strategy.dart';
import 'squat/squat_strategy.dart';

// Typedefs and DTW types re-exported so call sites don't need extra imports.
export 'curl/curl_strategy.dart'
    show RomThresholdsProvider, CurlRepCommitCallback;
export 'curl/dtw_scorer.dart' show DtwScore;

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

  /// Most recent peak forward-lean (deg, signed positive). Squat only.
  final double? squatLastRepLeanDeg;

  /// Most recent peak knee-shift ratio. Squat only — informational metric.
  final double? squatLastRepKneeShiftRatio;

  /// Most recent peak heel-lift ratio. Squat only.
  final double? squatLastRepHeelLiftRatio;

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
    this.squatLastRepLeanDeg,
    this.squatLastRepKneeShiftRatio,
    this.squatLastRepHeelLiftRatio,
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

  /// Per-rep squat quality scores accumulated this session (squat only).
  final List<double> _squatRepQualities = [];

  /// Squat-only completion callback. Fires once per committed squat rep
  /// with the analyzer's per-rep snapshot. Squat workouts use this to
  /// persist `reps.quality` + ratio metrics, mirroring the curl callback.
  final SquatRepCommitCallback? _onSquatRepCommit;

  DateTime? _lastTransitionTime;
  DateTime? _stateStartTime;

  final List<double> _angleBuffer = [];
  static const int _smoothWindow = 3;

  RepCounter({
    this.exercise = ExerciseType.bicepsCurl,
    this.side = ExerciseSide.both,
    RomThresholdsProvider? curlThresholdsProvider,
    CurlRepCommitCallback? onCurlRepCommit,
    CurlViewFlipCallback? onCurlViewFlipped,
    List<Duration> curlHistoricalConcentricDurations = const [],
    List<double>? curlReferenceRepAngleSeries,
    bool curlEnableDtwScoring = false,
    SquatVariant squatVariant = SquatVariant.bodyweight,
    bool squatLongFemurLifter = false,
    SquatRepCommitCallback? onSquatRepCommit,
  }) : _onSquatRepCommit = onSquatRepCommit {
    _strategy = _buildStrategy(
      exercise: exercise,
      side: side,
      curlThresholdsProvider: curlThresholdsProvider,
      onCurlRepCommit: onCurlRepCommit,
      onCurlViewFlipped: onCurlViewFlipped,
      curlHistoricalConcentricDurations: curlHistoricalConcentricDurations,
      curlReferenceRepAngleSeries: curlReferenceRepAngleSeries,
      curlEnableDtwScoring: curlEnableDtwScoring,
      squatVariant: squatVariant,
      squatLongFemurLifter: squatLongFemurLifter,
    );
  }

  static ExerciseStrategy _buildStrategy({
    required ExerciseType exercise,
    required ExerciseSide side,
    RomThresholdsProvider? curlThresholdsProvider,
    CurlRepCommitCallback? onCurlRepCommit,
    CurlViewFlipCallback? onCurlViewFlipped,
    List<Duration> curlHistoricalConcentricDurations = const [],
    List<double>? curlReferenceRepAngleSeries,
    bool curlEnableDtwScoring = false,
    SquatVariant squatVariant = SquatVariant.bodyweight,
    bool squatLongFemurLifter = false,
  }) => switch (exercise) {
    ExerciseType.bicepsCurlFront => CurlStrategy(
      exerciseType: ExerciseType.bicepsCurlFront,
      initialView: CurlCameraView.front,
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      onViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: curlHistoricalConcentricDurations,
      referenceRepAngleSeries: curlReferenceRepAngleSeries,
      enableDtwScoring: curlEnableDtwScoring,
    ),
    ExerciseType.bicepsCurlSide => CurlStrategy(
      exerciseType: ExerciseType.bicepsCurlSide,
      initialView: side == ExerciseSide.right
          ? CurlCameraView.sideRight
          : CurlCameraView.sideLeft,
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      onViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: curlHistoricalConcentricDurations,
      referenceRepAngleSeries: curlReferenceRepAngleSeries,
      enableDtwScoring: curlEnableDtwScoring,
    ),
    // ignore: deprecated_member_use_from_same_package
    ExerciseType.bicepsCurl => CurlStrategy(
      exerciseType: ExerciseType.bicepsCurlFront,
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      onViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: curlHistoricalConcentricDurations,
      referenceRepAngleSeries: curlReferenceRepAngleSeries,
      enableDtwScoring: curlEnableDtwScoring,
    ),
    ExerciseType.squat => SquatStrategy(
      variant: squatVariant,
      longFemurLifter: squatLongFemurLifter,
    ),
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
      _onSquatCommit();
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
    _squatRepQualities.clear();
    _strategy.onReset();
  }

  /// Score a candidate angle trace against the curl reference rep.
  /// Returns null for non-curl exercises or when DTW scoring is disabled.
  DtwScore? scoreCurlRep(List<double> candidate) {
    final strategy = _strategy;
    if (strategy is! CurlStrategy) return null;
    return strategy.scoreRep(candidate);
  }

  /// Per-rep curl form telemetry (lifecycle of the analyzer's max-trackers
  /// is `onRepStart` → `evaluate*` → `onRepEnd` — the trackers stay alive
  /// at commit time, cleared by the *next* `onRepStart`). Non-curl
  /// strategies return null so the caller can short-circuit.
  CurlFormAnalyzerExtras? get curlFormExtras {
    final strategy = _strategy;
    if (strategy is! CurlStrategy) return null;
    return strategy.formExtras;
  }

  // ── Internals ─────────────────────────────────────────────────────

  void _resetToIdle() {
    _state = RepState.idle;
    _stateStartTime = null;
  }

  /// Called once per committed rep, regardless of exercise. Squat-specific
  /// bookkeeping (quality accumulation + commit callback) lives here so
  /// the curl path is unchanged.
  void _onSquatCommit() {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return;
    final quality = strategy.lastRepQuality;
    if (quality != null) _squatRepQualities.add(quality);
    final cb = _onSquatRepCommit;
    if (cb != null) {
      cb(
        repIndex: _reps,
        quality: quality,
        leanDeg: strategy.lastRepLeanDeg,
        kneeShiftRatio: strategy.lastRepKneeShiftRatio,
        heelLiftRatio: strategy.lastRepHeelLiftRatio,
      );
    }
  }

  RepSnapshot _snapshot() {
    // Surface exercise-specific fields only when the active strategy matches.
    // One-per-frame downcast — acceptable cost for cross-layer clarity.
    final strategy = _strategy;
    final isCurl = strategy is CurlStrategy;
    final isSquat = strategy is SquatStrategy;
    final squatAvg = isSquat && _squatRepQualities.isNotEmpty
        ? _squatRepQualities.reduce((a, b) => a + b) / _squatRepQualities.length
        : null;
    return RepSnapshot(
      reps: _reps,
      sets: _sets,
      state: _state,
      jointAngle: _lastAngle,
      formErrors: _lastErrors,
      detectedView: isCurl ? strategy.lockedView : CurlCameraView.unknown,
      lastRepQuality: isCurl
          ? strategy.formExtras.lastRepQuality
          : (isSquat ? strategy.lastRepQuality : null),
      averageQuality: isCurl
          ? strategy.formExtras.averageQuality
          : (isSquat ? squatAvg : null),
      repQualities: isCurl
          ? strategy.formExtras.repQualities
          : (isSquat ? List.unmodifiable(_squatRepQualities) : const []),
      fatigueDetected: isCurl ? strategy.formExtras.fatigueDetected : false,
      eccentricTooFastCount: isCurl
          ? strategy.formExtras.eccentricTooFastCount
          : 0,
      errorsTriggered: const {},
      squatLastRepLeanDeg: isSquat ? strategy.lastRepLeanDeg : null,
      squatLastRepKneeShiftRatio: isSquat
          ? strategy.lastRepKneeShiftRatio
          : null,
      squatLastRepHeelLiftRatio: isSquat ? strategy.lastRepHeelLiftRatio : null,
    );
  }
}

/// Squat-only rep-commit callback. Fires once per committed rep with the
/// analyzer's per-rep snapshot (quality + ratio metrics).
typedef SquatRepCommitCallback =
    void Function({
      required int repIndex,
      required double? quality,
      required double? leanDeg,
      required double? kneeShiftRatio,
      required double? heelLiftRatio,
    });
