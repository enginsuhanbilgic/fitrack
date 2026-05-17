import '../core/constants.dart';
import '../core/form_thresholds.dart';
import '../core/squat_form_thresholds.dart';
import '../core/squat_rom_defaults.dart';
import '../core/types.dart';
import '../models/pose_result.dart';
import 'curl/curl_form_analyzer_extras.dart';
import 'curl/curl_strategy.dart';
import 'exercise_strategy.dart';
import 'plank/plank_strategy.dart';
import 'push_up/push_up_rom_profile.dart';
import 'push_up/push_up_strategy.dart';
import 'squat/squat_strategy.dart';

// Typedefs and DTW types re-exported so call sites don't need extra imports.
export 'curl/curl_strategy.dart'
    show RomThresholdsProvider, CurlRepCommitCallback;
export 'push_up/push_up_rom_profile.dart'
    show PushUpRomProfile, PushUpRomThresholds;
export 'push_up/push_up_strategy.dart' show PushUpRomThresholdsProvider;
export 'plank/plank_strategy.dart' show PlankStrategy;
export 'squat/squat_strategy.dart'
    show
        SquatRomThresholdsProvider,
        SquatLongFemurDetectedCallback,
        SquatRepExtremesCallback;

// ── Per-arm state machine (biceps curl only) ─────────────

// ── RepSnapshot ──────────────────────────────────────────

/// Everything the UI needs after every frame.
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

  /// Per-arm rep counts — only meaningful for bicepsCurl; both 0 otherwise.
  final int leftReps;
  final int rightReps;

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
    this.leftReps = 0,
    this.rightReps = 0,
    this.squatLastRepLeanDeg,
    this.squatLastRepKneeShiftRatio,
    this.squatLastRepHeelLiftRatio,
  });
}

/// Library-private callback fired once per committed push-up rep with the
/// rep's measured elbow extremes. Mirrors the squat-side extremes channel
/// in shape — both carry the per-rep ROM tuple consumed by the host's
/// telemetry-emitting handler.
///
/// Trimmed signature (vs squat's seven-field commit shape): the v1
/// derivation script consumes only `min_elbow` and `max_elbow`. Adding
/// `body_line_dev` / `quality` here would plumb four layers of unused
/// fields before a consumer exists for them — see plan §1.3 rationale.
typedef _OnPushUpRepCommit =
    void Function({
      required int repIndex,
      required double? minElbowAngle,
      required double? maxElbowAngle,

      /// Ascent (concentric/press) duration of the just-committed rep, as
      /// measured by `PushUpFormAnalyzer`. Nullable: a rep can commit before
      /// the analyzer stamped both phase boundaries (partial reps, skipped
      /// BOTTOM). Hosts treat null as "no data" and skip persistence.
      /// Added 2026-05-16 (curl-parity tempo/fatigue). The descent/eccentric
      /// duration is computed transiently for the too-fast cue and is NOT
      /// carried out — only the concentric duration feeds `concentric_ms`.
      required Duration? concentricDuration,
    });

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

  // ── Curl per-arm FSMs ─────────────────────────────────
  // ── Squat / push-up single FSM ────────────────────────
  RepState _state = RepState.idle;
  int _reps = 0;
  int _sets = 1;
  double? _lastAngle;
  List<FormError> _lastErrors = const [];

  /// Per-rep squat quality scores accumulated this session (squat only).
  final List<double> _squatRepQualities = [];

  /// Per-rep push-up quality scores accumulated this session (push-up only).
  final List<double> _pushUpRepQualities = [];

  /// Per-second plank quality scores accumulated this session (plank only).
  /// Clean seconds advance `_reps`; bad-pose seconds are retained only for
  /// the average-quality score.
  final List<double> _plankQualitySamples = [];
  int _lastPlankSampleIndex = 0;

  /// Squat-only completion callback. Fires once per committed squat rep
  /// with the analyzer's per-rep snapshot. Squat workouts use this to
  /// persist `reps.quality` + ratio metrics, mirroring the curl callback.
  final SquatRepCommitCallback? _onSquatRepCommit;

  /// Push-up-only completion callback. Fires once per committed push-up rep
  /// with the rep's measured elbow extremes — consumed by the host to emit
  /// the `pushup.rep` telemetry line. Null when the active exercise isn't
  /// push-up or when the host hasn't wired telemetry (e.g. tests).
  final _OnPushUpRepCommit? _onPushUpRepCommit;

  /// Squat min/max knee angles captured by the strategy's extremes callback
  /// at commit time, consumed by [_onSquatCommit] in the same `update()`
  /// pass before being cleared. Buffer-of-one — never holds across reps.
  double? _pendingSquatMinKneeAngle;
  double? _pendingSquatMaxKneeAngle;

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
    List<Duration> historicalConcentricDurations = const [],
    FormThresholds curlFormThresholds = FormThresholds.medium,
    SquatVariant squatVariant = SquatVariant.bodyweight,
    bool squatLongFemurLifter = false,
    SquatFormThresholds squatFormThresholds = SquatFormThresholds.defaults,
    SquatRomThresholdSet squatRomThresholds = SquatRomDefaults.defaults,
    SquatRomThresholdsProvider? squatThresholdsProvider,
    SquatRepCommitCallback? onSquatRepCommit,
    SquatLongFemurDetectedCallback? onSquatLongFemurDetected,
    double? squatPersistedFemurTorsoRatio,
    PushUpRomThresholds pushUpThresholds = PushUpRomThresholds.defaults,
    PushUpRomThresholdsProvider? pushUpThresholdsProvider,
    // Library-private typedef — external callers (WorkoutViewModel) pass a
    // method tearoff which Dart infers against the private type at the call
    // site, so the name itself never has to leak across libraries.
    // ignore: library_private_types_in_public_api
    _OnPushUpRepCommit? onPushUpRepCommit,
  }) : _onSquatRepCommit = onSquatRepCommit,
       _onPushUpRepCommit = onPushUpRepCommit {
    _strategy = _buildStrategy(
      exercise: exercise,
      side: side,
      curlThresholdsProvider: curlThresholdsProvider,
      onCurlRepCommit: onCurlRepCommit,
      onCurlViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: historicalConcentricDurations,
      curlFormThresholds: curlFormThresholds,
      squatVariant: squatVariant,
      squatLongFemurLifter: squatLongFemurLifter,
      squatFormThresholds: squatFormThresholds,
      squatRomThresholds: squatRomThresholds,
      squatThresholdsProvider: squatThresholdsProvider,
      onSquatRepExtremes: _handleSquatRepExtremes,
      onSquatLongFemurDetected: onSquatLongFemurDetected,
      squatPersistedFemurTorsoRatio: squatPersistedFemurTorsoRatio,
      pushUpThresholds: pushUpThresholds,
      pushUpThresholdsProvider: pushUpThresholdsProvider,
    );
  }

  static ExerciseStrategy _buildStrategy({
    required ExerciseType exercise,
    required ExerciseSide side,
    RomThresholdsProvider? curlThresholdsProvider,
    CurlRepCommitCallback? onCurlRepCommit,
    CurlViewFlipCallback? onCurlViewFlipped,
    List<Duration> historicalConcentricDurations = const [],
    FormThresholds curlFormThresholds = FormThresholds.medium,
    SquatVariant squatVariant = SquatVariant.bodyweight,
    bool squatLongFemurLifter = false,
    SquatFormThresholds squatFormThresholds = SquatFormThresholds.defaults,
    SquatRomThresholdSet squatRomThresholds = SquatRomDefaults.defaults,
    SquatRomThresholdsProvider? squatThresholdsProvider,
    SquatRepExtremesCallback? onSquatRepExtremes,
    SquatLongFemurDetectedCallback? onSquatLongFemurDetected,
    double? squatPersistedFemurTorsoRatio,
    PushUpRomThresholds pushUpThresholds = PushUpRomThresholds.defaults,
    PushUpRomThresholdsProvider? pushUpThresholdsProvider,
  }) => switch (exercise) {
    ExerciseType.bicepsCurlFront => CurlStrategy(
      exerciseType: ExerciseType.bicepsCurlFront,
      initialView: CurlCameraView.front,
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      onViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: historicalConcentricDurations,
      formThresholds: curlFormThresholds,
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
      historicalConcentricDurations: historicalConcentricDurations,
      formThresholds: curlFormThresholds,
    ),
    // ignore: deprecated_member_use_from_same_package
    ExerciseType.bicepsCurl => CurlStrategy(
      exerciseType: ExerciseType.bicepsCurlFront,
      side: side,
      thresholdsProvider: curlThresholdsProvider,
      onRepCommit: onCurlRepCommit,
      onViewFlipped: onCurlViewFlipped,
      historicalConcentricDurations: historicalConcentricDurations,
      formThresholds: curlFormThresholds,
    ),
    ExerciseType.squat => SquatStrategy(
      variant: squatVariant,
      longFemurLifter: squatLongFemurLifter,
      formThresholds: squatFormThresholds,
      romThresholds: squatRomThresholds,
      thresholdsProvider: squatThresholdsProvider,
      onRepExtremes: onSquatRepExtremes,
      onLongFemurDetected: onSquatLongFemurDetected,
      persistedFemurTorsoRatio: squatPersistedFemurTorsoRatio,
      historicalConcentricDurations: historicalConcentricDurations,
    ),
    ExerciseType.pushUp => PushUpStrategy(
      thresholds: pushUpThresholds,
      thresholdsProvider: pushUpThresholdsProvider,
      historicalConcentricDurations: historicalConcentricDurations,
    ),
    ExerciseType.plank => PlankStrategy(),
  };

  /// Strategy's extremes callback — buffers min/max for the unified
  /// [_onSquatCommit] which fires the host's combined commit callback.
  void _handleSquatRepExtremes({
    required int repIndex,
    required double minKneeAngle,
    required double maxKneeAngle,
  }) {
    _pendingSquatMinKneeAngle = minKneeAngle;
    _pendingSquatMaxKneeAngle = maxKneeAngle;
  }

  // ── Public API ────────────────────────────────────────

  RepSnapshot update(PoseResult result) {
    final now = DateTime.now();
    final angle = _strategy.computePrimaryAngle(result);
    _lastAngle = angle;

    if (angle == null) return _snapshot();

    _angleBuffer.add(angle);
    if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
    final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    // Stuck-state watchdog (invariant 2).
    if (_strategy is! PlankStrategy &&
        _state != RepState.idle &&
        _stateStartTime != null) {
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
    _capturePlankSecondSample();

    if (output.repCommitted) {
      _reps++;
      _onSquatCommit();
      _onPushUpCommit();
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

  void updatePushUpThresholds(PushUpRomThresholds thresholds) {
    final strategy = _strategy;
    if (strategy is PushUpStrategy) {
      strategy.updateThresholds(thresholds);
    }
  }

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
    _pushUpRepQualities.clear();
    _plankQualitySamples.clear();
    _lastPlankSampleIndex = 0;
    _strategy.onReset();
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

  /// Frame count from the most recent ASCENDING window — feeds the
  /// `squat.hip_lead` telemetry line. Null when the active strategy is
  /// not squat. Cleared by the strategy at the next IDLE → DESCENDING
  /// transition, so the host must read this between commit and the next
  /// rep start.
  int? get squatAscendingFrameCount {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return null;
    return strategy.ascendingFrameCount;
  }

  /// Frame count from the most recent early-descent window — feeds the
  /// `squat.knee_led` telemetry line's `window_frames` field. Null when
  /// the active strategy is not squat. Same read-window semantics as
  /// [squatAscendingFrameCount] — cleared at the next IDLE → DESCENDING.
  int? get squatKneeLedSampleCount {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return null;
    return strategy.kneeLedSampleCount;
  }

  /// The depth gate (`_effectiveBottomAngle`) actually ENFORCED by the
  /// squat FSM for the most recent rep — `kSquatBottomAngle` (80°) by
  /// default, or `kLongFemurBottomAngle` (100°) if the long-femur path
  /// relaxed it this session. Distinct from the resolved
  /// `SquatRomThresholdSet.bottomAngle` tuple field (which is defined but
  /// NOT consumed at FSM-transition time). Null when the active strategy
  /// is not squat. The host logs this on `squat.rep` so the offline
  /// threshold-derivation workflow sees the gate that was truly applied,
  /// not the dead tuple value.
  double? get squatEffectiveBottomAngle {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return null;
    return strategy.effectiveBottomAngle;
  }

  /// Live signed forward-lean angle (deg) from the squat analyzer's
  /// most recent frame. Positive = forward, negative = backward. Null
  /// when the active strategy is not squat OR the analyzer hasn't seen
  /// a high-confidence shoulder/hip pair yet. The HUD reads this for
  /// the real-time lean indicator (Cue 3, 2026-05-15).
  double? get squatCurrentSignedLeanDeg {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return null;
    return strategy.currentSignedLeanDeg;
  }

  /// Computes the squat's primary joint angle (knee angle, averaged over
  /// both sides when both are above the confidence gate) without driving
  /// the FSM. Used by [WorkoutViewModel] during the squat-calibration
  /// phase to feed the `RepBoundaryDetector` without entering ACTIVE.
  /// Returns null when the active strategy is not squat, or when neither
  /// side has the required landmarks.
  double? computeSquatPrimaryAngle(PoseResult pose) {
    final strategy = _strategy;
    if (strategy is! SquatStrategy) return null;
    return strategy.computePrimaryAngle(pose);
  }

  // ── Internals ─────────────────────────────────────────────────────

  void _resetToIdle() {
    _state = RepState.idle;
    _stateStartTime = null;
  }

  /// Called once per committed rep, regardless of exercise. Squat-specific
  /// bookkeeping (quality accumulation + commit callback) lives here so
  /// the curl path is unchanged. Drains the strategy's pending extremes
  /// buffer into the unified callback — the buffer is reset after firing
  /// so a subsequent non-extremes commit can't accidentally reuse stale
  /// values.
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
        minKneeAngle: _pendingSquatMinKneeAngle,
        maxKneeAngle: _pendingSquatMaxKneeAngle,
        hipLeadRatio: strategy.lastRepHipLeadRatio,
        leanExceedFrac: strategy.lastRepLeanExceedFrac,
        kneeLedRatio: strategy.lastRepKneeLedRatio,
        signedLeanAtPeak: strategy.lastRepSignedLeanAtPeak,
        backwardLeanFrameCount: strategy.lastRepBackwardLeanFrameCount,
        concentricDuration: strategy.lastConcentricDuration,
      );
    }
    _pendingSquatMinKneeAngle = null;
    _pendingSquatMaxKneeAngle = null;
  }

  void _onPushUpCommit() {
    final strategy = _strategy;
    if (strategy is! PushUpStrategy) return;
    final quality = strategy.lastRepQuality;
    if (quality != null) _pushUpRepQualities.add(quality);
    // Telemetry callback. Reads the analyzer's snapshot fields directly —
    // no internal buffer needed because the analyzer captures the extremes
    // inside `consumeCompletionErrors` (already invoked by the strategy's
    // commit branch before this method runs).
    _onPushUpRepCommit?.call(
      repIndex: _reps,
      minElbowAngle: strategy.lastRepMinElbowAngle,
      maxElbowAngle: strategy.lastRepMaxElbowAngle,
      concentricDuration: strategy.lastConcentricDuration,
    );
  }

  void _capturePlankSecondSample() {
    final strategy = _strategy;
    if (strategy is! PlankStrategy) return;
    final sample = strategy.lastSecondSample;
    if (sample == null || sample.index == _lastPlankSampleIndex) return;
    _lastPlankSampleIndex = sample.index;
    _plankQualitySamples.add(sample.quality);
  }

  RepSnapshot _snapshot() {
    // Surface exercise-specific fields only when the active strategy matches.
    // One-per-frame downcast — acceptable cost for cross-layer clarity.
    final strategy = _strategy;
    final isCurl = strategy is CurlStrategy;
    final isSquat = strategy is SquatStrategy;
    final isPushUp = strategy is PushUpStrategy;
    final isPlank = strategy is PlankStrategy;
    final squatAvg = isSquat && _squatRepQualities.isNotEmpty
        ? _squatRepQualities.reduce((a, b) => a + b) / _squatRepQualities.length
        : null;
    final pushUpAvg = isPushUp && _pushUpRepQualities.isNotEmpty
        ? _pushUpRepQualities.reduce((a, b) => a + b) /
              _pushUpRepQualities.length
        : null;
    final plankAvg = isPlank && _plankQualitySamples.isNotEmpty
        ? _plankQualitySamples.reduce((a, b) => a + b) /
              _plankQualitySamples.length
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
          : (isSquat
                ? strategy.lastRepQuality
                : (isPushUp
                      ? strategy.lastRepQuality
                      : (isPlank ? plankAvg : null))),
      averageQuality: isCurl
          ? strategy.formExtras.averageQuality
          : (isSquat
                ? squatAvg
                : (isPushUp ? pushUpAvg : (isPlank ? plankAvg : null))),
      repQualities: isCurl
          ? strategy.formExtras.repQualities
          : (isSquat
                ? List.unmodifiable(_squatRepQualities)
                : (isPushUp
                      ? List.unmodifiable(_pushUpRepQualities)
                      : (isPlank
                            ? List.unmodifiable(_plankQualitySamples)
                            : const []))),
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
/// analyzer's per-rep snapshot (quality + ratio metrics + ROM extremes).
///
/// `minKneeAngle` / `maxKneeAngle` come from the strategy's extremes
/// channel — they may be null on edge-case commits where one or both
/// extremes weren't captured (rare). The host must tolerate null for both
/// fields and skip the auto-calibrator + persistent bucket update when
/// either is missing.
typedef SquatRepCommitCallback =
    void Function({
      required int repIndex,
      required double? quality,
      required double? leanDeg,
      required double? kneeShiftRatio,
      required double? heelLiftRatio,
      required double? minKneeAngle,
      required double? maxKneeAngle,
      required double? hipLeadRatio,
      required double? leanExceedFrac,
      required double? kneeLedRatio,

      /// Signed lean (forward = +, backward = −) at the |lean| peak of the
      /// just-committed rep. Bug-4 sign-convention diagnostic — distinct
      /// from the abs() `leanDeg`. Null when no lean frame was measured.
      required double? signedLeanAtPeak,

      /// Frames in the just-committed rep that fired
      /// `excessiveBackwardLean`. High value with `leanExceedFrac≈0` ⇒
      /// sign inversion at the camera. Diagnostic only.
      required int backwardLeanFrameCount,

      /// Ascent (concentric/lift) duration of the just-committed rep, as
      /// measured by `SquatFormAnalyzer`. Nullable: a rep can commit
      /// without a measured ascent (edge cases). Hosts treat null as "no
      /// data" and skip persistence. Added 2026-05-16 (curl-parity
      /// tempo/fatigue). Only the concentric duration is carried out — it
      /// feeds `concentric_ms` + the cross-session fatigue baseline. The
      /// descent/eccentric duration is graded transiently for the
      /// too-fast cue and is NOT persisted.
      required Duration? concentricDuration,
    });
