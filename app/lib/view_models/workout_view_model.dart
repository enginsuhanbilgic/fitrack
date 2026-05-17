import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/exercise_targets.dart';
import '../core/form_thresholds.dart';
import '../core/squat_form_thresholds.dart';
import '../core/platform_config.dart';
import '../core/rom_thresholds.dart';
import '../core/types.dart';
import '../engine/angle_utils.dart';
import '../core/squat_rom_defaults.dart';
import '../engine/curl/curl_auto_calibrator.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../engine/curl/mad_outlier.dart' as mad;
import '../engine/curl/rep_boundary_detector.dart';
import '../engine/landmark_smoother.dart';
import '../engine/push_up/push_up_auto_calibrator.dart';
import '../engine/rep_counter.dart';
import '../engine/setup_framing_check.dart';
import '../engine/squat/squat_auto_calibrator.dart';
// Prefix-import to keep squat profile types distinct at every call site —
// helps grep across the VM since both exercises have similarly-named
// bucket/profile classes.
import '../engine/squat/squat_rom_profile.dart'
    as squat_profile
    show SquatRomProfile, SquatRomBucket;
// Re-export SquatRomProfile under its bare name on the public API of this
// library so SquatSessionContext consumers (summary screen, tests) can
// reference it without learning about the prefix indirection.
import '../engine/squat/squat_rom_profile.dart' show SquatRomProfile;
import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import '../services/camera_service.dart';
import '../services/db/preferences_repository.dart';
import '../services/db/profile_repository.dart';
import '../services/db/session_repository.dart';
import '../services/pose/mlkit_pose_service.dart';
import '../services/pose/pose_service.dart';
import '../services/telemetry_log.dart';
import '../services/tts_service.dart';
import 'telemetry/pushup_rep_line.dart';

/// Squat-specific session state bundled for the post-session Form Audit
/// (Squat Pipeline Overhaul — Part 4).
///
/// Bundling rationale: the Form Audit needs four squat-specific inputs
/// (variant, long-femur lifter, session sensitivity, optional profile,
/// optional auto-cal snapshot). Adding all of them as flat fields on
/// [WorkoutCompletedEvent] would tip the event past the maintainability
/// threshold (already 16+ fields). This value class adds **one**
/// nullable field instead — null for non-squat sessions, populated by
/// `_triggerCompleted` for squat sessions.
///
/// The flat fields ([WorkoutCompletedEvent.squatVariant],
/// [WorkoutCompletedEvent.squatLongFemurLifter],
/// [WorkoutCompletedEvent.squatRepMetrics]) are retained for backward
/// compatibility with the live summary screen rendering — both surfaces
/// can read from either path during the migration.
class SquatSessionContext {
  const SquatSessionContext({
    required this.variant,
    required this.longFemurLifter,
    required this.feedbackSensitivity,
    this.profile,
    this.autoCalSnapshot,
  });

  /// Squat variant the session ran with — drives the lean threshold.
  final SquatVariant variant;

  /// True if the "Tall lifter" Settings toggle was on for this session.
  /// Adds [SquatFormThresholds.longFemurLeanBoost] to the lean gate.
  final bool longFemurLifter;

  /// Session sensitivity — drives form-error thresholds + cold-start ROM
  /// fallback in the audit.
  final FeedbackSensitivity feedbackSensitivity;

  /// Personal squat ROM profile. Drives Tier 1 of the audit's per-rep
  /// ROM-bar resolver when [SquatRomProfile.isCalibrated] is true.
  final SquatRomProfile? profile;

  /// Session-end auto-calibrator snapshot. Drives Tier 2 when no
  /// calibrated profile bucket is available.
  final SquatRomThresholdSet? autoCalSnapshot;
}

/// Value emitted on the completion stream when a workout ends.
///
/// The VM never holds a `BuildContext`; instead it hands the widget a
/// fully-populated snapshot so the widget can push `SummaryScreen` without
/// reaching back into a disposing VM.
class WorkoutCompletedEvent {
  final ExerciseType exercise;
  final int totalReps;
  final int totalSets;
  final Duration sessionDuration;
  final double? averageQuality;
  final CurlCameraView detectedView;
  final List<double> repQualities;
  final bool fatigueDetected;
  final bool asymmetryDetected;
  final int eccentricTooFastCount;
  final Set<FormError> errorsTriggered;
  final Map<FormError, int> errorCounts;
  final List<CurlRepRecord> curlRepRecords;
  final List<CurlProfileBucketSummary> curlBucketSummaries;

  /// Squat variant the session ran with. `bodyweight` for non-squat sessions.
  final SquatVariant squatVariant;

  /// True if the "Tall lifter" toggle was on for this session.
  final bool squatLongFemurLifter;

  /// Per-rep squat metrics, index-aligned with the rep order. Empty for
  /// non-squat sessions.
  final List<SquatRepMetrics> squatRepMetrics;

  /// Per-rep biceps-curl side-view metrics, index-aligned with the rep
  /// order. Empty for non-curl sessions.
  final List<BicepsSideRepMetrics> bicepsSideRepMetrics;

  /// The curl ROM profile in effect for this session, if any. Drives the
  /// Form Audit's Tier-1 (personal calibration) bar for the relevant
  /// `(side, view)` bucket. Null when the user has never calibrated curl
  /// or when this isn't a curl session.
  final CurlRomProfile? curlProfile;

  /// The push-up ROM profile in effect for this session, if any. Drives the
  /// Form Audit's Tier-1 personal-calibration bar for push-up depth/start
  /// gates. Null when the user has never calibrated push-up or when this
  /// isn't a push-up session.
  final PushUpRomProfile? pushUpProfile;

  /// Snapshot of the auto-calibrator's session-end thresholds, if it
  /// accumulated viable state. Drives the Form Audit's Tier-2 bar when no
  /// calibrated `(side, view)` bucket exists. Null when auto-cal didn't
  /// reach the ≥2-rep + viable-ROM gate, or when this isn't a curl session.
  final RomThresholds? autoCalSnapshot;

  /// Sensitivity the session ran at. Drives the Form Audit's form-error
  /// thresholds (swing/shrug/lean/etc.) and the cold-start fallback's ROM
  /// gates when no personalized data is available.
  final FeedbackSensitivity feedbackSensitivity;

  /// Per-rep concentric duration in milliseconds, index-aligned with the
  /// rep order. NULL for reps where the FSM didn't capture a concentric
  /// duration (rare — abandoned reps). Drives the summary card's TEMPO
  /// stat (`avg of non-null / 1000`).
  final List<int?> repConcentricMs;

  /// Per-rep depth as a fraction (0.0–1.0) of the user's reference range,
  /// index-aligned with the rep order. NULL when no reference range is
  /// available (e.g. non-curl sessions with zero session-max ROM).
  /// Reference range is the calibrated bucket's peak ROM when available
  /// (curl), else the session's max ROM (fallback). Drives the summary
  /// card's DEPTH stat (`avg of non-null × 100`).
  final List<double?> repDepthPercents;

  /// Squat-specific Form Audit context — variant, long-femur state,
  /// session sensitivity, personal profile (if any), auto-cal snapshot
  /// (if any). Null for non-squat sessions and for reconstructed history
  /// sessions where the live state isn't persisted. See
  /// [SquatSessionContext] doc-block for the bundling rationale.
  final SquatSessionContext? squatContext;

  const WorkoutCompletedEvent({
    required this.exercise,
    required this.totalReps,
    required this.totalSets,
    required this.sessionDuration,
    required this.averageQuality,
    required this.detectedView,
    required this.repQualities,
    required this.fatigueDetected,
    required this.asymmetryDetected,
    required this.eccentricTooFastCount,
    required this.errorsTriggered,
    this.errorCounts = const {},
    required this.curlRepRecords,
    required this.curlBucketSummaries,
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
    this.curlProfile,
    this.pushUpProfile,
    this.autoCalSnapshot,
    this.feedbackSensitivity = FeedbackSensitivity.medium,
    this.repConcentricMs = const [],
    this.repDepthPercents = const [],
    this.squatContext,
  });
}

/// Post-calibration summary card payload.
class CalibrationSummary {
  final String viewLabel;
  final String sidesLabel;
  const CalibrationSummary({required this.viewLabel, required this.sidesLabel});
}

/// Push-up manual calibration protocol stages (2026-05-15 redesign).
///
/// `observeReps` collects per-rep top/bottom extremes from
/// [kPushUpCalibrationTargetReps] valid reps via a slim local-min/max
/// detector ([_PushUpCalibrationRepDetector]) — replaces the pre-2026-05-15
/// hold-and-average protocol (`topHold` / `bottomHold` / `rise`) which read
/// statically held angles that drift higher than the user's actual rep
/// extremes. `confirm` shows the captured anchors + derived gates and
/// awaits the user's accept/redo.
enum _PushUpCalibrationStage { observeReps, confirm }

/// Per-rep top/bottom extreme detector used during push-up calibration.
///
/// Pure signal-processing component: watches the elbow-angle stream and
/// emits a `(top, bottom)` pair every time the user completes one descent
/// + ascent cycle that crosses the validity thresholds. Does NOT drive the
/// production push-up FSM — it shares a name with what the live strategy
/// does but is intentionally simpler so calibration can't accidentally
/// affect live rep counting.
///
/// State machine:
///   awaitingTop → descending  (top captured, angle started falling)
///   descending  → ascending   (rolling min established, angle started rising)
///   ascending   → emit + awaitingTop  (angle back at top threshold)
///
/// Rep validity: requires (top − bottom) ≥ [kPushUpCalibrationMinExcursion]
/// at emit time. Otherwise the cycle is silently discarded (e.g. a
/// micro-bounce while user shifts position).
class _PushUpCalibrationRepDetector {
  _PushUpCalibrationRepStage _stage = _PushUpCalibrationRepStage.awaitingTop;
  double? _runningTop;
  double? _runningBottom;

  /// Process one frame's elbow angle. Returns a `(top, bottom)` pair when
  /// a valid rep has just completed; null otherwise. Caller is responsible
  /// for the body-line / posture check — the detector accepts any angle
  /// stream and only enforces the geometric rep shape.
  (double top, double bottom)? onAngle(double angle) {
    switch (_stage) {
      case _PushUpCalibrationRepStage.awaitingTop:
        if (angle >= kPushUpCalibrationRepTopMinAngle) {
          _runningTop = angle;
          _runningBottom = angle;
          _stage = _PushUpCalibrationRepStage.descending;
        }
        return null;
      case _PushUpCalibrationRepStage.descending:
        final top = _runningTop ?? angle;
        // Keep the highest observed top — user may rise slightly before the
        // real descent begins.
        if (angle > top) _runningTop = angle;
        // Track the descending minimum.
        if (_runningBottom == null || angle < _runningBottom!) {
          _runningBottom = angle;
        }
        // Begin ascent when angle starts rising off the bottom by at least
        // a small hysteresis margin (3°). Avoids flipping to ascending on
        // jitter while the user is still descending.
        if (_runningBottom != null && angle > _runningBottom! + 3.0) {
          _stage = _PushUpCalibrationRepStage.ascending;
        }
        return null;
      case _PushUpCalibrationRepStage.ascending:
        // If the user reverses and goes deeper, treat as a new descent.
        final currentBottom = _runningBottom;
        if (currentBottom != null && angle < currentBottom) {
          _runningBottom = angle;
          _stage = _PushUpCalibrationRepStage.descending;
          return null;
        }
        // Rep completes when the angle returns to a near-locked-out top.
        if (angle >= kPushUpCalibrationRepTopMinAngle) {
          final top = _runningTop;
          final bottom = currentBottom;
          _stage = _PushUpCalibrationRepStage.awaitingTop;
          _runningTop = null;
          _runningBottom = null;
          if (top == null || bottom == null) return null;
          if ((top - bottom) < kPushUpCalibrationMinExcursion) return null;
          return (top, bottom);
        }
        return null;
    }
  }

  void reset() {
    _stage = _PushUpCalibrationRepStage.awaitingTop;
    _runningTop = null;
    _runningBottom = null;
  }
}

enum _PushUpCalibrationRepStage { awaitingTop, descending, ascending }

/// All engine, phase, calibration, TTS and UI-observable state for a single
/// workout session. UI subscribes via [ChangeNotifier]; the widget never owns
/// mutable state beyond what the framework itself requires (controllers etc.).
class WorkoutViewModel extends ChangeNotifier {
  // ── Config ─────────────────────────────────────────────
  final ExerciseType exercise;
  final bool forceCalibration;

  /// User-declared side facing the camera for side-view curls. Drives the
  /// initial `CurlCameraView` seed in `RepCounter`/`CurlStrategy` so the
  /// view-aware landmark gate demands the correct arm's landmarks from
  /// frame one. Ignored for non-curl exercises and front-view curls.
  /// Defaults to `ExerciseSide.both`, which falls back to sideLeft seeding
  /// (legacy behavior) — preserves existing call sites until UI is wired.
  final ExerciseSide curlSide;

  /// Diagnostic-only flag. When true the threshold resolver short-circuits to
  /// `RomThresholds.global(view)` for every rep regardless of profile state,
  /// the auto-calibrator is never fed, and the rep-commit path skips bucket
  /// promotion. This lets you collect a clean `source=global` paste for the
  /// default-threshold derivation workflow. NEVER ship a workout in this
  /// mode for normal use — every rep runs on cold-start defaults, defeating
  /// the entire personal-calibration system.
  ///
  /// Read from `PreferencesRepository.getDiagnosticDisableAutoCalibration()`
  /// during `init()` and frozen for the rest of the VM's lifetime
  /// (snapshot-on-construction — same pattern as the squat long-femur flag).
  /// Settings toggling mid-session does NOT affect an in-flight workout.
  bool _diagnosticDisableAutoCalibration = false;
  bool get diagnosticDisableAutoCalibration =>
      _diagnosticDisableAutoCalibration;

  /// User-facing **auto-calibration** preference (2026-05-15 split). When
  /// false, the in-session auto-calibrator (tier 2) is skipped — but a
  /// calibrated personal profile (tier 1) is STILL honored. Use
  /// [diagnosticDisableAutoCalibration] to force cold-start globals across
  /// every tier. Snapshot-on-construction; mid-session Settings changes
  /// take effect on the *next* workout.
  bool _autoCalibrationEnabled = true;
  bool get autoCalibrationEnabled => _autoCalibrationEnabled;

  /// Whether this session is running as a *curl debug session*. When
  /// true the workout silently observes — no TTS, no haptics, no banners,
  /// no form-error cues — and emits a periodic `pose.frame_metrics`
  /// telemetry line at [kDebugFrameMetricsHz] so frame-level distributions
  /// are visible even when no rep commits. Forces
  /// [_diagnosticDisableAutoCalibration] true (every rep `source=global`)
  /// so the data is consistent regardless of the orthogonal toggle.
  ///
  /// Read from `PreferencesRepository.getCurlDebugSession()` during
  /// `init()` and frozen for the rest of the VM's lifetime
  /// (snapshot-on-construction). Settings toggling mid-session does NOT
  /// affect an in-flight workout. Always false when the active exercise
  /// is not a biceps curl variant.
  bool _isCurlDebugSession = false;
  bool get isCurlDebugSession => _isCurlDebugSession;

  /// Unified form/ROM coaching sensitivity for all exercises. Read from
  /// [PreferencesRepository.getFeedbackSensitivity] during [init] and frozen
  /// for the session (snapshot-on-construction). Affects only cold-start
  /// (`ThresholdSource.global`) reps — calibrated and auto-calibrated paths
  /// are unaffected.
  FeedbackSensitivity _feedbackSensitivity = FeedbackSensitivity.medium;

  /// How chatty the spoken coaching is. Read from
  /// [PreferencesRepository.getTtsVerbosity] during [init] and frozen for
  /// the session. Caps the number of TTS fires per *form error* per
  /// session — visual highlights and the session-end summary are
  /// unaffected. See [_onFormErrors] for the gate.
  TtsVerbosity _ttsVerbosity = TtsVerbosity.medium;

  /// User Form Tolerance Percent in `[0, 100]`. Read from
  /// [PreferencesRepository.getFormTolerancePercent] during [init] and
  /// frozen for the session. Scales the curl form-audit dead-band layer
  /// only — does NOT affect rep counting, quality scoring, or
  /// post-session audit summaries. See `FormThresholds.withTolerance` for
  /// the interpolation formula.
  int _formTolerancePercent = kDefaultFormTolerancePercent;

  /// Wall-clock timestamp of the most recent `pose.frame_metrics` emit.
  /// Throttles emission to roughly [kDebugFrameMetricsHz] regardless of
  /// the camera's frame rate. Null until the first debug-session frame.
  DateTime? _lastDebugFrameMetricsAt;

  /// Diagnostic-mode rep counter. Lives separately from `_curlRepRecords`
  /// because diagnostic mode intentionally does not write to the records
  /// list (no bucket promotion, no summary-screen population). Reset to 0
  /// per VM lifetime; only incremented inside the diagnostic branch.
  int _diagnosticRepIndex = 0;

  // ── Services ───────────────────────────────────────────
  final CameraService _camera;
  final PoseService _pose;
  final TtsService _tts;
  final ProfileRepository _profileRepository;
  final SessionRepository _sessionRepository;
  final PreferencesRepository _preferencesRepository;
  late final RepCounter _repCounter;
  final int targetCount;

  // ── Engine ─────────────────────────────────────────────
  final LandmarkSmoother _displaySmoother = LandmarkSmoother(
    minCutoff: kOneEuroDisplayMinCutoff,
    beta: kOneEuroDisplayBeta,
    dCutoff: kOneEuroDisplayDCutoff,
  );
  CurlRomProfile? _profile;
  PushUpRomProfile? _pushUpProfile;
  squat_profile.SquatRomProfile? _squatProfile;
  final CurlAutoCalibrator _autoCalibrator = CurlAutoCalibrator();

  /// In-session squat auto-calibrator. Resets at every set boundary
  /// (no view-lock concept for squat). Drives Tier 2 of the squat
  /// threshold resolver until a [SquatRomProfile] bucket reaches the
  /// calibration sample-count gate.
  final SquatAutoCalibrator _squatAutoCalibrator = SquatAutoCalibrator();

  /// In-session push-up auto-calibrator. Resets at every set boundary
  /// (push-up has no view-lock concept, mirroring squat). Drives Tier 2
  /// of the push-up threshold resolver until a [PushUpRomProfile]
  /// reaches the calibration sample-count gate. Anchored on min/max of
  /// MAD-accepted rolling window — see file-level doc on
  /// [PushUpAutoCalibrator] for the design.
  final PushUpAutoCalibrator _pushUpAutoCalibrator = PushUpAutoCalibrator();

  /// Set when the squat profile's bucket received an `applyRep` whose
  /// result actually updated state — drives the lazy save on session
  /// end. Mirrors `_profileDirty` for curl.
  bool _squatProfileDirty = false;
  bool _profileDirty = false;

  // ── Calibration phase ──────────────────────────────────
  RepBoundaryDetector? _calibrationDetector;
  StreamSubscription<RepExtreme>? _calibrationSub;
  Timer? _calibrationTimeoutTimer;
  int _calibrationReps = 0;
  int _calibrationSecondsRemaining = kCalibrationTimeoutSec;
  String? _calibrationError;
  double? _calibrationCurrentAngle;
  final List<RepExtreme> _calibrationCollected = [];
  CalibrationSummary? _calibrationSummary;
  _PushUpCalibrationStage _pushUpCalibrationStage =
      _PushUpCalibrationStage.observeReps;
  final _PushUpCalibrationRepDetector _pushUpCalibrationRepDetector =
      _PushUpCalibrationRepDetector();
  final List<double> _pushUpCalibrationTopSamples = [];
  final List<double> _pushUpCalibrationBottomSamples = [];
  double? _pushUpCalibrationTopAngle;
  String _pushUpCalibrationInstruction =
      'Do 3 controlled push-ups at your normal tempo.';

  // ── Lifecycle / phase ──────────────────────────────────
  bool _isReady = false;
  bool _isProcessing = false;
  String? _error;

  /// Monotonic clock for frame throttling. `Stopwatch.elapsedMilliseconds`
  /// is allocation-free (vs. two `DateTime` objects per ~30 Hz camera
  /// callback) and immune to wall-clock skew — an NTP/user clock change
  /// mid-session can't make the throttle burst (negative delta) or stall
  /// (huge delta). `_lastProcessedMs` starts far in the past so the first
  /// frame always passes (replaces the epoch-0 `DateTime` sentinel).
  final Stopwatch _frameClock = Stopwatch()..start();
  int _lastProcessedMs = -1 << 30;

  /// Last time we emitted a `workout.frame_dropped` telemetry entry.
  /// Throttled to 1/sec so a degraded session (a per-frame exception at
  /// ~15 fps) can't flood the 500-entry ring buffer in ~33 seconds.
  /// Mirrors `MlKitPoseService._maybeWarnQuality`'s throttle.
  DateTime? _lastFrameDropWarnAt;

  WorkoutPhase _phase = WorkoutPhase.setupCheck;

  // SETUP_CHECK.
  int _setupOkFrames = 0;
  // Last framing verdict surfaced to UI during SETUP_CHECK. Null until the
  // first setup frame is evaluated. See `setup_framing_check.dart`.
  String? _setupFramingHint;
  Map<int, Color> _landmarkColors = {};

  // COUNTDOWN.
  int _countdownValue = kCountdownSeconds;
  Timer? _countdownTimer;

  // ACTIVE.
  DateTime? _absenceStart;
  DateTime? _activeStart;

  /// Wall-clock moment the active phase began. UI uses this to render
  /// session elapsed time in the live HUD. Null until the countdown
  /// completes and the engine transitions to [WorkoutPhase.active].
  DateTime? get activeStartedAt => _activeStart;

  final Map<FormError, DateTime> _lastFeedbackTime = {};
  final Map<FormError, int> _formErrorCounts = {};

  /// Per-error count of cap-suppressed (muted) cooldown-clears since the last
  /// time the voice was allowed to speak this error. Drives the persistence
  /// re-arm in [_onFormErrors]: when it reaches the verbosity's re-arm window
  /// ([kTtsPersistenceReArmRepsMedium] / [kTtsPersistenceReArmRepsLow]), one
  /// extra cue is allowed and this resets to 0. Audio-only — does not touch
  /// detection, `_formErrorCounts`, highlights, or the summary. Keyed by the
  /// actual error (matching `_formErrorCounts`), NOT the cooldown key, so the
  /// asymmetry L/R independence is preserved. Same VM-lifetime reset lifecycle
  /// as `_formErrorCounts` (fresh map per session, no explicit clear).
  final Map<FormError, int> _mutedFireStreak = {};

  // Visual highlight state.
  Map<int, Color> _errorHighlight = {};
  Timer? _highlightTimer;

  // Mid-session occlusion.
  DateTime? _occlusionStart;
  int _occlusionResumeFrames = 0;
  bool _isOccluded = false;
  DateTime? _lastOcclusionTts;

  // Curl view detection.
  CurlCameraView _detectedCurlView = CurlCameraView.unknown;

  // Hole #1 passive uncalibrated-view notice.
  String? _uncalibratedViewNotice;

  /// Camera-framing hint state. Set when the pose service has reported
  /// `lastFrameNearEdge=true` for [_kFramingHintFrames] consecutive
  /// frames during SETUP_CHECK or COUNTDOWN. Cleared on the first clean
  /// frame.
  String? _framingHint;
  int _nearEdgeStreak = 0;
  static const int _kFramingHintFrames = 30;

  // Push-up landscape uses the OS-coherent rotation model (the push-up
  // WorkoutScreen unlocks SystemChrome landscape; OS rotates UI + camera +
  // buffer together). No engine-side orientation state is required — the
  // accelerometer-driven approach was reverted 2026-05-16 (see WISDOM:
  // iOS desyncs buffer-vs-declared rotation under a portrait UI lock).

  Timer? _uncalibratedNoticeTimer;

  // Runtime view-flip advisory banner. Set whenever the engine reports
  // [CurlStrategy.onViewFlipped]; auto-cleared after 2s.
  String? _viewFlipBannerText;
  Timer? _viewFlipBannerTimer;
  static const Duration _kViewFlipBannerDuration = Duration(seconds: 2);

  static const List<int> _pushUpLeftSideLandmarks = [
    LM.leftShoulder,
    LM.leftElbow,
    LM.leftWrist,
    LM.leftHip,
    LM.leftAnkle,
  ];
  static const List<int> _pushUpRightSideLandmarks = [
    LM.rightShoulder,
    LM.rightElbow,
    LM.rightWrist,
    LM.rightHip,
    LM.rightAnkle,
  ];
  static const List<int> _plankLeftCoreLandmarks = [
    LM.leftShoulder,
    LM.leftElbow,
    LM.leftHip,
  ];
  static const List<int> _plankRightCoreLandmarks = [
    LM.rightShoulder,
    LM.rightElbow,
    LM.rightHip,
  ];
  static const List<int> _plankLeftLowerLandmarks = [
    LM.leftKnee,
    LM.leftAnkle,
  ];
  static const List<int> _plankRightLowerLandmarks = [
    LM.rightKnee,
    LM.rightAnkle,
  ];

  // Per-frame display state.
  List<PoseLandmark> _landmarks = [];
  RepSnapshot _snapshot = const RepSnapshot(
    reps: 0,
    sets: 1,
    state: RepState.idle,
  );

  // Per-rep detail records for summary screen (curl only).
  final List<CurlRepRecord> _curlRepRecords = [];

  /// Per-rep concentric durations, index-aligned with `_curlRepRecords` so
  /// that rep N in the DB carries the duration captured at its commit time.
  /// Values are nullable: the analyzer reports `null` when a rep commits
  /// before `onPeakReached` fires (edge cases). Consumed by
  /// `_persistCompletedSession` in PR4 and by `SqliteSessionRepository` via
  /// `insertCompletedSession`'s `concentricDurations` arg.
  final List<Duration?> _repConcentricDurations = [];

  /// Squat variant snapshot. Read in [init] from [PreferencesRepository]
  /// before the [RepCounter] is constructed; immutable for the session
  /// (snapshot-on-construction — plan flow-decision #2).
  SquatVariant _squatVariant = SquatVariant.bodyweight;

  /// "Tall lifter" toggle snapshot. Same lifecycle as `_squatVariant`.
  bool _squatLongFemurLifter = false;

  /// Per-rep squat metrics, index-aligned with rep order. Empty for
  /// non-squat sessions. Populated by `_handleSquatRepCommit`.
  final List<SquatRepMetrics> _squatRepMetrics = [];

  /// True when this session runs in squat debug mode. Snapshot-on-construction.
  bool _isSquatDebugSession = false;

  /// True when this session runs in push-up debug mode.
  /// Snapshot-on-construction (read once in [init], frozen for the workout —
  /// Settings toggling mid-session does not affect an in-flight workout).
  /// Always false when the active exercise is not push-up or when
  /// [kPushUpDebugSessionEnabled] is compiled out. Mirrors
  /// [_isSquatDebugSession]. Forces tier-3 unmodified thresholds + silent
  /// observation so the FSM-threshold telemetry baseline is clean.
  bool _isPushUpDebugSession = false;
  bool get isPushUpDebugSession => _isPushUpDebugSession;

  /// Monotonic rep index for squat.rep telemetry lines.
  int _squatDebugRepIndex = 0;

  /// Monotonic rep index for pushup.rep telemetry lines. Parallels
  /// `_squatDebugRepIndex` — incremented unconditionally on every push-up
  /// rep commit so the offline derivation script can join rows by `rep=`.
  /// Reset on session start / hard reset along with the rep counter.
  int _pushUpDebugRepIndex = 0;

  /// Timestamp of the last squat frame-metric emission (throttle guard).
  DateTime? _lastSquatDebugFrameMetricsAt;

  /// Per-rep biceps-curl side-view metrics. Populated by
  /// [_handleCurlRepCommit] when `exercise == bicepsCurlSide` AND the
  /// locked view is `sideLeft` / `sideRight`. Read by
  /// [_persistCompletedSession] (PR 3) and exported to the SQLite `reps`
  /// table (schema v5). Empty for non-side-view sessions.
  final List<BicepsSideRepMetrics> _bicepsSideRepMetrics = [];

  // Completion channel — widget pushes SummaryScreen on emission.
  final StreamController<WorkoutCompletedEvent> _completionCtrl =
      StreamController.broadcast();

  // Per-error landmark highlight indices (multi-exercise — curl + squat).
  // Squat highlights stack by region (shoulders+hips for lean, knees for
  // shift, heels for heel-lift) so multiple cues can flash simultaneously
  // without color collision (plan flow-decision #6).
  static const Map<FormError, List<int>> _errorLandmarks = {
    // Curl
    FormError.torsoSwing: [LM.leftShoulder, LM.rightShoulder],
    FormError.depthSwing: [LM.leftShoulder, LM.rightShoulder],
    FormError.shoulderArc: [LM.leftShoulder, LM.rightShoulder],
    FormError.elbowDrift: [LM.leftElbow, LM.rightElbow],
    FormError.elbowRise: [LM.leftElbow, LM.rightElbow],
    FormError.shoulderShrug: [LM.leftShoulder, LM.rightShoulder],
    FormError.backLean: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
    ],
    FormError.shortRomStart: [LM.leftShoulder, LM.rightShoulder],
    FormError.shortRomPeak: [LM.leftWrist, LM.rightWrist],
    FormError.asymmetryLeftLag: [LM.leftElbow, LM.leftWrist],
    FormError.asymmetryRightLag: [LM.rightElbow, LM.rightWrist],
    // Squat
    FormError.excessiveForwardLean: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
    ],
    // Backward lean shares the same geometric story (shoulder vs hip vertical
    // alignment) so it highlights the same landmark set as forward lean.
    FormError.excessiveBackwardLean: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
    ],
    FormError.forwardKneeShift: [LM.leftKnee, LM.rightKnee],
    FormError.heelLift: [LM.leftHeel, LM.rightHeel],
    // Hip-lead manifests as hips rising faster than shoulders — the user's
    // chest collapses forward as they ascend. Highlighting both shoulder
    // and hip pairs makes the geometric story visible.
    FormError.hipLead: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
    ],
    // trunkTibia retained — legacy session rendering path.
    FormError.trunkTibia: [LM.leftHip, LM.rightHip],
    // Push-up
    FormError.hipSag: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
      LM.leftAnkle,
      LM.rightAnkle,
    ],
    FormError.pushUpShortRom: [LM.leftElbow, LM.rightElbow],
    FormError.plankArmAngle: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftElbow,
      LM.rightElbow,
      LM.leftWrist,
      LM.rightWrist,
    ],
    FormError.plankBodyLine: [
      LM.leftShoulder,
      LM.rightShoulder,
      LM.leftHip,
      LM.rightHip,
      LM.leftAnkle,
      LM.rightAnkle,
    ],
  };

  WorkoutViewModel({
    required this.exercise,
    required ProfileRepository profileRepository,
    required SessionRepository sessionRepository,
    required PreferencesRepository preferencesRepository,
    int? targetCount,
    this.forceCalibration = false,
    this.curlSide = ExerciseSide.both,
    CameraService? camera,
    PoseService? pose,
    TtsService? tts,
  }) : targetCount = ExerciseTargetConfig.forExercise(
         exercise,
       ).sanitize(targetCount),
       _camera = camera ?? CameraService(),
       _pose = pose ?? MlKitPoseService(),
       _tts = tts ?? TtsService(),
       _profileRepository = profileRepository,
       _sessionRepository = sessionRepository,
       _preferencesRepository = preferencesRepository;

  // ── Public read-only getters (widget-observable state) ──
  bool get isReady => _isReady;
  String? get error => _error;
  WorkoutPhase get phase => _phase;
  int get setupOkFrames => _setupOkFrames;
  String? get setupFramingHint => _setupFramingHint;
  Map<int, Color> get landmarkColors => _landmarkColors;
  int get countdownValue => _countdownValue;
  List<PoseLandmark> get landmarks => _landmarks;
  RepSnapshot get snapshot => _snapshot;
  Map<int, Color> get errorHighlight => _errorHighlight;
  bool get isOccluded => _isOccluded;
  CurlCameraView get detectedCurlView => _detectedCurlView;
  String? get uncalibratedViewNotice => _uncalibratedViewNotice;

  /// Camera-framing hint. Non-null while the user's body has been near
  /// the frame edges for a sustained period during pre-active phases.
  /// UI should render as a passive banner so the user can re-frame
  /// before the rep counter starts.
  String? get framingHint => _framingHint;

  /// Runtime view-flip advisory text. Surfaced by [WorkoutScreen] as a
  /// transient amber banner. Null when no flip has happened recently or
  /// the 2s auto-dismiss has elapsed.
  String? get viewFlipBanner => _viewFlipBannerText;
  int get calibrationReps => _calibrationReps;
  int get calibrationSecondsRemaining => _calibrationSecondsRemaining;
  String? get calibrationError => _calibrationError;
  double? get calibrationCurrentAngle => _calibrationCurrentAngle;

  /// Live signed forward-lean (deg) from the squat analyzer's most recent
  /// frame. Positive = forward; negative = backward; null when the active
  /// exercise is not squat or the analyzer hasn't seen a high-confidence
  /// shoulder/hip pair yet. The workout HUD reads this for the real-time
  /// lean readout (Cue 3, 2026-05-15). Updates per `notifyListeners()` —
  /// no separate stream needed since the view-model already notifies on
  /// every pose snapshot.
  double? get squatCurrentSignedLeanDeg =>
      _repCounter.squatCurrentSignedLeanDeg;
  CalibrationSummary? get calibrationSummary => _calibrationSummary;
  int get calibrationProgressTarget => switch (exercise) {
    ExerciseType.pushUp => 3,
    ExerciseType.squat => kSquatCalibrationMinReps,
    _ => kCalibrationMinReps,
  };
  String get calibrationProgressLabel =>
      exercise == ExerciseType.pushUp ? 'steps' : 'reps';
  String get calibrationInstruction => switch (exercise) {
    ExerciseType.pushUp => _pushUpCalibrationInstruction,
    ExerciseType.squat =>
      'Squat through your full natural range — '
          '$kSquatCalibrationMinReps reps.',
    _ => 'Curl through your full natural range — $kCalibrationMinReps reps.',
  };

  /// True once a `forceCalibration: true` session has finished its calibration
  /// summary and should pop back to whatever route launched the recalibrate
  /// flow (Settings → Recalibrate). The screen listens for this transition and
  /// performs the navigation — the VM never imports `Navigator`.
  ///
  /// One-shot: flips false → true exactly once per VM lifetime, and stays true
  /// until the screen consumes it. The first-time / auto-cal path (where
  /// `forceCalibration == false`) never sets this flag, so the workout
  /// continues into setupCheck → countdown → active as before.
  bool get shouldExitAfterCalibration => _shouldExitAfterCalibration;
  bool _shouldExitAfterCalibration = false;
  CameraService get camera => _camera;
  CurlRomProfile? get profile => _profile;
  Stream<WorkoutCompletedEvent> get completionEvents => _completionCtrl.stream;

  // ── Init ───────────────────────────────────────────────
  Future<void> init() async {
    try {
      await _pose.init();
      await _camera.init();
      await _tts.init();
      // Load profile AND historical fatigue baseline before constructing the
      // RepCounter, so the analyzer sees both from rep 1. Failures on either
      // load are non-fatal: profile falls back to empty, baseline to empty
      // list (analyzer collapses to in-session-only fatigue detection —
      // pre-WP5.4 behavior).
      var historical = const <Duration>[];
      if (exercise.isCurl) {
        _profile = await _profileRepository.loadCurl() ?? CurlRomProfile();
        try {
          historical = await _sessionRepository.recentConcentricDurations(
            exercise: exercise,
            window: const Duration(days: 30),
          );
        } catch (e, st) {
          TelemetryLog.instance.log(
            'fatigue.baseline.load_failed',
            e.toString(),
            data: <String, Object?>{'stackTrace': st.toString()},
          );
        }
        // Sensitivity snapshot must come before the debug-session block so the
        // curl_debug.session_start telemetry log includes the real value.
        _feedbackSensitivity = await _preferencesRepository
            .getFeedbackSensitivity();
        _ttsVerbosity = await _preferencesRepository.getTtsVerbosity();
        // Form Tolerance Percent — snapshot once. Same pattern as TTS
        // verbosity: mid-session Settings changes do not affect an
        // in-flight workout. Scales the curl form-audit dead-band layer
        // via the FormThresholds.withTolerance factory wired into the
        // RepCounter constructor below.
        _formTolerancePercent = await _preferencesRepository
            .getFormTolerancePercent();
        TelemetryLog.instance.log(
          'form_tolerance.session_start',
          'percent=$_formTolerancePercent',
        );
        // Diagnostic flag — snapshot once, identical to other curl prefs.
        // A mid-session toggle in Settings has no effect on this run (matches
        // the squat long-femur "snapshot-on-construction" rule).
        _diagnosticDisableAutoCalibration = await _preferencesRepository
            .getDiagnosticDisableAutoCalibration();
        // Auto-calibration preference — separate from diagnostic mode
        // (2026-05-15 split). Diagnostic mode overrides everything; this
        // flag only controls whether tier-2 in-session auto-cal runs.
        _autoCalibrationEnabled = await _preferencesRepository
            .getAutoCalibrationEnabled();
        // Curl-debug-session snapshot. Read AFTER the diagnostic toggle so
        // the implicit "debug-session forces diagnostic on" rule below is
        // ordering-independent of which Settings switch the user flipped
        // first. Compile-time gated on `kCurlDebugSessionEnabled` — when
        // the constant is false, the pref read still runs (cheap, defaults
        // false) but the dead branch tree-shakes.
        if (kCurlDebugSessionEnabled) {
          _isCurlDebugSession = await _preferencesRepository
              .getCurlDebugSession();
          if (_isCurlDebugSession) {
            // Force diagnostic-mode on so debug-session reps are uniformly
            // tagged `source=global` even if the orthogonal Settings toggle
            // happens to be off. Two separate user-facing switches, one
            // unambiguous data shape downstream.
            _diagnosticDisableAutoCalibration = true;
            // Expand the ring buffer for the session lifetime so frame
            // metrics + rep lines from long sets don't overflow the default
            // 500-entry cap. resetCap() is called in dispose().
            TelemetryLog.instance.setCap(kDebugRingBufferSize);
            TelemetryLog.instance.log(
              'curl_debug.session_active',
              'silent observation mode — feedback suppressed; '
                  'frame_metrics @ ${kDebugFrameMetricsHz}Hz; '
                  'ring_buffer=$kDebugRingBufferSize',
            );
            // Session-boundary marker. Carries a wall-clock timestamp so
            // multi-session pastes can be split unambiguously, and the
            // exact threshold values + flag state so the retune pipeline
            // knows which gates every rep.extremes line ran under.
            final debugView = curlSide == ExerciseSide.right
                ? CurlCameraView.sideRight
                : CurlCameraView.sideLeft;
            final debugThresholds = RomThresholds.global(debugView);
            TelemetryLog.instance.log(
              'curl_debug.session_start',
              'ts=${DateTime.now().toIso8601String()} '
                  'exercise=${exercise.name} '
                  'side=${curlSide.name} '
                  'view=${debugView.name} '
                  'sensitivity=${_feedbackSensitivity.name} '
                  'thresholds_start=${debugThresholds.startAngle.toStringAsFixed(1)} '
                  'thresholds_peak=${debugThresholds.peakAngle.toStringAsFixed(1)} '
                  'thresholds_peak_exit=${debugThresholds.peakExitAngle.toStringAsFixed(1)} '
                  'thresholds_end=${debugThresholds.endAngle.toStringAsFixed(1)} '
                  'use_telemetry_defaults=$kUseTelemetryRomDefaults '
                  'use_pipeline_defaults=$kUsePipelineRomDefaults',
            );
          }
        }
        if (_diagnosticDisableAutoCalibration) {
          TelemetryLog.instance.log(
            'diagnostic.mode_active',
            'diagnostic mode ON — every rep will run on source=global '
                '(overrides personal profile and auto-calibration)',
          );
        } else if (!_autoCalibrationEnabled) {
          TelemetryLog.instance.log(
            'autocal.disabled',
            'auto-calibration OFF — calibrated profile still honored; '
                'tier-2 auto-cal will be skipped',
          );
        }
      } else if (exercise == ExerciseType.squat) {
        // Snapshot squat preferences before constructing RepCounter so the
        // strategy + analyzer freeze on the values that were active at
        // workout start. Mid-session Settings changes apply to the next
        // workout (plan flow-decision #2).
        _squatVariant = await _preferencesRepository.getSquatVariant();
        _squatLongFemurLifter = await _preferencesRepository
            .getSquatLongFemurLifter();
        _feedbackSensitivity = await _preferencesRepository
            .getFeedbackSensitivity();
        // Load the persisted squat profile if one exists. Null on first
        // launch or after a reset — `_resolveSquatThresholds` handles the
        // null path via Tier 2 (auto-cal) or Tier 3 (cold-start).
        _squatProfile = await _profileRepository.loadSquat();
        // Cross-session fatigue baseline (2026-05-16, curl-parity). Same
        // 30-day window + try/catch as the curl branch. The repo method is
        // exercise-parameterized — squat uses an exact-name match, so no
        // repo change is needed. Empty on failure → analyzer collapses to
        // in-session-only fatigue (graceful, mirrors curl).
        try {
          historical = await _sessionRepository.recentConcentricDurations(
            exercise: exercise,
            window: const Duration(days: 30),
          );
        } catch (e, st) {
          TelemetryLog.instance.log(
            'fatigue.baseline.load_failed',
            e.toString(),
            data: <String, Object?>{'stackTrace': st.toString()},
          );
        }
        // Unified global diagnostic toggle (2026-05-15). Same pref the curl
        // branch reads above — all three exercises now respond to a single
        // "Disable auto-calibration" Settings switch. Squat resolver
        // short-circuits to `SquatRomThresholdSet.anchor` (unmodified
        // High anchor, no sensitivity post-pass) when this flag is true.
        _diagnosticDisableAutoCalibration = await _preferencesRepository
            .getDiagnosticDisableAutoCalibration();
        _autoCalibrationEnabled = await _preferencesRepository
            .getAutoCalibrationEnabled();
        if (_diagnosticDisableAutoCalibration) {
          TelemetryLog.instance.log(
            'diagnostic.mode_active',
            'diagnostic mode ON — squat rep will run on source=global '
                '(overrides personal profile and auto-calibration)',
          );
        } else if (!_autoCalibrationEnabled) {
          TelemetryLog.instance.log(
            'autocal.disabled',
            'squat auto-calibration OFF — calibrated profile still honored; '
                'tier-2 auto-cal will be skipped',
          );
        }
        if (kSquatDebugSessionEnabled) {
          _isSquatDebugSession = await _preferencesRepository
              .getSquatDebugSession();
          if (_isSquatDebugSession) {
            // Parity with curl debug-session contract: when a squat debug
            // session is active, every rep MUST run against unmodified
            // tier-3 globals so the derivation pipeline gets a clean
            // baseline. Enforcement lives inside `_resolveSquatThresholds`
            // — that resolver checks `_isSquatDebugSession` and short-
            // circuits to `SquatRomThresholdSet.anchor` (the unmodified
            // High anchor, no sensitivity post-pass). Mirrors the curl
            // resolver's `globalUnmodified` short-circuit at line ~789.
            TelemetryLog.instance.setCap(kSquatDebugRingBufferSize);
            TelemetryLog.instance.log(
              'squat_debug.session_active',
              'silent observation mode — feedback suppressed; '
                  'ring_buffer=$kSquatDebugRingBufferSize '
                  'frame_metrics@${kSquatDebugFrameMetricsHz}Hz',
            );
            TelemetryLog.instance.log(
              'squat_debug.session_start',
              'ts=${DateTime.now().toIso8601String()} '
                  'exercise=${exercise.name} '
                  'variant=${_squatVariant.name} '
                  'long_femur=$_squatLongFemurLifter '
                  'sensitivity=${_feedbackSensitivity.name} '
                  'start_angle=$kSquatStartAngle '
                  'bottom_angle=$kSquatBottomAngle '
                  'end_angle=$kSquatEndAngle '
                  'lean_warn_bodyweight=$kSquatLeanWarnDegBodyweight '
                  'lean_warn_hbbs=$kSquatLeanWarnDegHBBS '
                  'knee_shift_warn=$kSquatKneeShiftWarnRatio '
                  'heel_lift_warn=$kSquatHeelLiftWarnRatio',
            );
            // Diagnostic marker — mirrors the curl path so derivation
            // scripts can split sessions on the same event regardless of
            // exercise.
            TelemetryLog.instance.log(
              'diagnostic.mode_active',
              'auto-calibration disabled — every rep will run on source=global',
            );
          }
        }
      } else if (exercise == ExerciseType.pushUp) {
        _pushUpProfile = await _profileRepository.loadPushUp();
        // Cross-session fatigue baseline (2026-05-16, curl-parity). Same
        // contract as the curl + squat branches.
        try {
          historical = await _sessionRepository.recentConcentricDurations(
            exercise: exercise,
            window: const Duration(days: 30),
          );
        } catch (e, st) {
          TelemetryLog.instance.log(
            'fatigue.baseline.load_failed',
            e.toString(),
            data: <String, Object?>{'stackTrace': st.toString()},
          );
        }
        // Unified global diagnostic toggle (2026-05-15). Same pref the
        // curl and squat branches read — when true, the resolver line
        // below (`pushUpThresholds:` in the RepCounter constructor)
        // selects `PushUpRomThresholds.defaults` over the saved profile.
        _diagnosticDisableAutoCalibration = await _preferencesRepository
            .getDiagnosticDisableAutoCalibration();
        _autoCalibrationEnabled = await _preferencesRepository
            .getAutoCalibrationEnabled();
        if (_diagnosticDisableAutoCalibration) {
          TelemetryLog.instance.log(
            'diagnostic.mode_active',
            'diagnostic mode ON — push-up rep will run on defaults '
                '(overrides calibrated profile and auto-calibration)',
          );
        } else if (!_autoCalibrationEnabled) {
          TelemetryLog.instance.log(
            'autocal.disabled',
            'push-up auto-calibration OFF — calibrated profile still honored; '
                'tier-2 auto-cal will be skipped',
          );
        }
        if (kPushUpDebugSessionEnabled) {
          _isPushUpDebugSession = await _preferencesRepository
              .getPushUpDebugSession();
          if (_isPushUpDebugSession) {
            // Parity with curl/squat debug-session contract: when a push-up
            // debug session is active, every rep MUST run against unmodified
            // tier-3 globals (`PushUpRomThresholds.defaults`, NO sensitivity
            // post-pass) so the offline derivation pipeline gets a clean
            // baseline. Enforcement lives inside `_resolvePushUpThresholds`
            // — that resolver checks `_isPushUpDebugSession` and short-
            // circuits. Mirrors the squat resolver's `_isSquatDebugSession`
            // short-circuit.
            TelemetryLog.instance.setCap(kPushUpDebugRingBufferSize);
            TelemetryLog.instance.log(
              'pushup_debug.session_active',
              'silent observation mode — feedback suppressed; '
                  'ring_buffer=$kPushUpDebugRingBufferSize '
                  'frame_metrics@${kPushUpDebugFrameMetricsHz}Hz',
            );
            // Universal session boundary. The offline derivation script
            // (`derive_pushup_thresholds_from_telemetry.py`) splits sessions
            // on `curl_debug.session_start` — push-up does NOT emit an
            // exercise-specific boundary (verified against the script's
            // `text.split("curl_debug.session_start")`). Emit it so a pasted
            // push-up debug log is parseable by the existing pipeline.
            TelemetryLog.instance.log(
              'curl_debug.session_start',
              'ts=${DateTime.now().toIso8601String()} '
                  'exercise=${exercise.name} '
                  'sensitivity=${_feedbackSensitivity.name} '
                  'start_angle=$kPushUpStartAngle '
                  'bottom_angle=$kPushUpBottomAngle '
                  'shallow_max=$kPushUpShallowRepMaxAngle '
                  'end_angle=$kPushUpEndAngle',
            );
            // Push-up-specific, human-readable session header (richer than
            // the universal marker; not consumed by the splitter).
            TelemetryLog.instance.log(
              'pushup_debug.session_start',
              'ts=${DateTime.now().toIso8601String()} '
                  'exercise=${exercise.name} '
                  'sensitivity=${_feedbackSensitivity.name} '
                  'start_angle=$kPushUpStartAngle '
                  'bottom_angle=$kPushUpBottomAngle '
                  'shallow_max=$kPushUpShallowRepMaxAngle '
                  'end_angle=$kPushUpEndAngle',
            );
            // Diagnostic marker — mirrors the curl/squat path so derivation
            // scripts can split sessions on the same event regardless of
            // exercise.
            TelemetryLog.instance.log(
              'diagnostic.mode_active',
              'push-up debug session — every rep will run on '
                  'PushUpRomThresholds.defaults (tier 3, no sensitivity)',
            );
          }
        }
      }
      _repCounter = RepCounter(
        exercise: exercise,
        side: curlSide,
        curlThresholdsProvider: _resolveThresholds,
        onCurlRepCommit: _handleCurlRepCommit,
        onCurlViewFlipped: _handleCurlViewFlipped,
        historicalConcentricDurations: historical,
        // Form-audit thresholds are fixed (Sensitivity vs Form Audit doctrine,
        // .agent_brain/SKILLS.md, 2026-05-14). The user's `_feedbackSensitivity`
        // affects ROM gates only — form audit always runs at the biomechanical
        // bar regardless of tier.
        curlFormThresholds: FormThresholds.withTolerance(_formTolerancePercent),
        squatVariant: _squatVariant,
        squatLongFemurLifter: _squatLongFemurLifter,
        squatFormThresholds: SquatFormThresholds.defaults,
        // Cold-start fallback for the strategy's `_romThresholds` field —
        // used when the host's provider returns nothing or isn't wired.
        // Tier 3 of the resolver lives in `_resolveSquatThresholds`; the
        // strategy's fallback is what runs in test paths and any future
        // non-VM call site.
        squatRomThresholds: SquatRomThresholdSet.forSensitivity(
          _feedbackSensitivity,
        ),
        squatThresholdsProvider: _resolveSquatThresholds,
        onSquatRepCommit: _handleSquatRepCommit,
        onSquatLongFemurDetected: _handleSquatLongFemurDetected,
        squatPersistedFemurTorsoRatio: _squatProfile?.bucket?.femurTorsoRatio,
        // Push-up resolver wiring (2026-05-15, plan Phase 3). Mirrors
        // curl/squat: a synchronous provider is invoked per rep at the
        // IDLE → DESCENDING transition inside `PushUpStrategy.tick`, and
        // the resolver function applies the three-tier precedence
        // (calibrated → auto-cal → defaults) per the truth table in
        // `.agent_brain/SKILLS.md`.
        //
        // The seed `pushUpThresholds:` value below is what the strategy
        // uses on the very first rep BEFORE the provider has been called
        // (defensive — covers tests and any future code path that
        // constructs `RepCounter` without consulting the provider).
        // Identical math to what the resolver returns for the same input
        // state, so behavior is consistent regardless of which path is
        // taken.
        pushUpThresholds: _resolvePushUpThresholds(0),
        pushUpThresholdsProvider: _resolvePushUpThresholds,
        onPushUpRepCommit: _handlePushUpRepCommit,
      );
      if ((exercise.isCurl ||
              exercise == ExerciseType.pushUp ||
              exercise == ExerciseType.squat) &&
          forceCalibration) {
        // Personal calibration is opt-in only — Settings → Recalibrate sets
        // `forceCalibration`. We never launch it automatically. Squat
        // calibration is opt-in per the `feedback_calibration_opt_in.md`
        // memory: only the gear/Settings entry-point opens the overlay.
        _enterCalibration();
      }
      _camera.startStream(_onFrame);
      _isReady = true;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // ── ROM Profile glue ──────────────────────────────────
  RomThresholds _resolveThresholds(
    ProfileSide side,
    CurlCameraView view,
    int repInSet,
  ) {
    // Diagnostic short-circuit: every rep gets cold-start defaults so the
    // `rep.extremes` log is uniformly tagged `source=global`. Skips both the
    // calibrated-bucket path and the auto-cal path; nothing else.
    if (diagnosticDisableAutoCalibration) {
      // Intentionally no sensitivity — debug sessions collect baseline data
      // against the unmodified Medium-baseline globals the Python script was
      // calibrated against. Applying sensitivity would make the measurements
      // circular. See `RomThresholds.globalUnmodified`.
      final t = RomThresholds.globalUnmodified(view);
      _logCurlThresholdsResolved(
        tier: 3,
        source: 'global',
        thresholds: t,
        extra: 'diagnostic=true',
      );
      return t;
    }
    final profile = _profile;
    if (profile != null && view != CurlCameraView.unknown) {
      final bucket = profile.bucketFor(side, view);
      if (bucket != null && bucket.sampleCount >= kCalibrationMinReps) {
        final warmup = repInSet < kProfileWarmupReps;
        final t = RomThresholds.fromBucket(
          bucket,
          warmup: warmup,
        ).applySensitivity(_feedbackSensitivity);
        _logCurlThresholdsResolved(
          tier: 1,
          source: warmup ? 'warmup' : 'calibrated',
          thresholds: t,
          extra: 'samples=${bucket.sampleCount}',
        );
        return t;
      }
    }
    // Tier 2 — in-session auto-calibrator. Gated by the user-facing
    // auto-calibration preference (2026-05-15 split). When the user
    // disables auto-cal, tier 1 still applies (handled above) but the
    // resolver falls straight to tier 3 here, skipping mid-session
    // refinement.
    if (_autoCalibrationEnabled) {
      final auto = _autoCalibrator.currentThresholds;
      if (auto != null) {
        final t = auto.applySensitivity(_feedbackSensitivity);
        _logCurlThresholdsResolved(
          tier: 2,
          source: 'autoCalibrated',
          thresholds: t,
        );
        return t;
      }
    }
    // Cold-start path. Sensitivity is applied inside `RomThresholds.global`
    // (the three-tier resolver uses tier-specific looseness deltas).
    final t = RomThresholds.global(view, _feedbackSensitivity);
    _logCurlThresholdsResolved(tier: 3, source: 'global', thresholds: t);
    return t;
  }

  void _logCurlThresholdsResolved({
    required int tier,
    required String source,
    required RomThresholds thresholds,
    String? extra,
  }) {
    TelemetryLog.instance.log(
      'curl.thresholds_resolved',
      'tier=$tier source=$source '
          'sensitivity=${_feedbackSensitivity.name} '
          'start=${thresholds.startAngle.toStringAsFixed(2)} '
          'peak=${thresholds.peakAngle.toStringAsFixed(2)} '
          'peakExit=${thresholds.peakExitAngle.toStringAsFixed(2)} '
          'end=${thresholds.endAngle.toStringAsFixed(2)}'
          '${extra != null ? ' $extra' : ''}',
    );
  }

  /// Engine-callback: a view flip just committed at FSM idle. Surface a
  /// 2-second amber advisory so the user sees the system adapt. Mirrors
  /// the existing transient-banner patterns in `WorkoutScreen`.
  void _handleCurlViewFlipped(CurlCameraView from, CurlCameraView to) {
    // Curl debug session: suppress the banner. The flip still happens
    // engine-side (analyzer's view changes, telemetry tags update); the
    // user just doesn't see a UI advisory about it. Matches the rest of
    // the silent-observation contract.
    if (kCurlDebugSessionEnabled && _isCurlDebugSession) {
      return;
    }
    final String text;
    switch (to) {
      case CurlCameraView.front:
        text = "Front view isn't supported yet — please turn 90°";
      case CurlCameraView.sideLeft:
        text = 'Detected you turned — now tracking left side';
      case CurlCameraView.sideRight:
        text = 'Detected you turned — now tracking right side';
      case CurlCameraView.unknown:
        // Defensive: the strategy contract forbids firing with to==unknown,
        // but if that ever changes we don't want to surface garbage copy.
        return;
    }
    _viewFlipBannerTimer?.cancel();
    _viewFlipBannerText = text;
    notifyListeners();
    _viewFlipBannerTimer = Timer(_kViewFlipBannerDuration, () {
      _viewFlipBannerText = null;
      notifyListeners();
    });
  }

  void _handleCurlRepCommit({
    required ProfileSide side,
    required CurlCameraView view,
    required double minAngle,
    required double maxAngle,
    required Duration? concentricDuration,
    double? minAtPeak,
  }) {
    // Diagnostic mode: don't feed the auto-calibrator and don't write the
    // bucket. Emit a `rep.extremes` line in the same format as the normal
    // path so the paste workflow is identical, but tag `source=global` /
    // `result=diagnosticSkipped` so the parser can identify diagnostic-mode
    // reps unambiguously. Uses a private counter (NOT `_curlRepRecords`)
    // because we're intentionally not growing that list in diagnostic mode.
    if (diagnosticDisableAutoCalibration) {
      _diagnosticRepIndex++;
      // `min_at_peak` separates "user held a real peak" (≈ minAngle) from
      // "FSM crossed the gate then noise pulled minAngle lower" (much
      // higher than minAngle). Critical for filtering out the 2D-pose
      // wrist-snap artifact at peak elbow flexion.
      TelemetryLog.instance.log(
        'rep.extremes',
        'rep=$_diagnosticRepIndex '
            'side=${side.name} '
            'view=${view.name} '
            'min=${minAngle.toStringAsFixed(1)} '
            'max=${maxAngle.toStringAsFixed(1)} '
            'rom=${(maxAngle - minAngle).toStringAsFixed(1)} '
            'min_at_peak=${minAtPeak?.toStringAsFixed(1) ?? "null"} '
            'concentric_ms=${concentricDuration?.inMilliseconds ?? -1} '
            'source=global '
            'result=diagnosticSkipped',
      );
      // Diagnostic mode skips bucket persistence and `_curlRepRecords`
      // (intentional — avoid contaminating calibration buckets), but
      // it MUST still emit the side-form telemetry. Retuning defaults
      // is the entire purpose of diagnostic mode; without these lines
      // the workflow has no data to work from. Schema is identical to
      // the production path below — same parser handles both.
      if (exercise == ExerciseType.bicepsCurlSide &&
          (view == CurlCameraView.sideLeft ||
              view == CurlCameraView.sideRight)) {
        final extras = _repCounter.curlFormExtras;
        if (extras != null) {
          final declaredArmIsLeft = side == ProfileSide.left;
          final resolvedArmIsLeft = extras.activeArmIsLeftThisRep;
          final armMatch = declaredArmIsLeft == resolvedArmIsLeft;
          final poseFacing = extras.facingRightThisRep == null
              ? 'unknown'
              : (extras.facingRightThisRep! ? 'right' : 'left');
          TelemetryLog.instance.log(
            'rep.arm_resolved',
            'rep=$_diagnosticRepIndex '
                'declared_side=${declaredArmIsLeft ? "left" : "right"} '
                'declared_view=${view.name} '
                'resolved_arm=${resolvedArmIsLeft ? "left" : "right"} '
                'committed_side=${side.name} '
                'left_conf=${extras.leftArmConfidenceSumThisRep.toStringAsFixed(2)} '
                'right_conf=${extras.rightArmConfidenceSumThisRep.toStringAsFixed(2)} '
                'pose_facing=$poseFacing '
                'arm_match=$armMatch',
          );
          TelemetryLog.instance.log(
            'rep.side_metrics',
            'rep=$_diagnosticRepIndex '
                'side=${side.name} '
                'view=${view.name} '
                'lean_deg=${extras.maxTorsoLeanDegThisRep.toStringAsFixed(2)} '
                'shoulder_drift_ratio=${extras.maxShoulderDriftRatioThisRep.toStringAsFixed(4)} '
                'elbow_drift_ratio=${extras.maxElbowDriftRatioThisRep.toStringAsFixed(4)} '
                'elbow_drift_signed=${extras.signedElbowDriftRatioAtMax?.toStringAsFixed(4) ?? "null"} '
                'back_lean_deg=${extras.maxBackLeanDegThisRep.toStringAsFixed(2)} '
                'shrug_ratio=${extras.maxShrugRatioThisRep.toStringAsFixed(4)} '
                'elbow_rise_ratio=${extras.maxElbowRiseRatioThisRep.toStringAsFixed(4)} '
                'rep_quality=${extras.lastRepQuality.toStringAsFixed(3)} '
                'concentric_ms=${concentricDuration?.inMilliseconds ?? -1} '
                'source=global',
          );
        }
      }
      return;
    }
    // Calibration-opt-in contract (2026-05-15): the live rep-commit path
    // NEVER mutates the personal profile or the in-session auto-calibrator
    // unless the user has explicitly enabled auto-calibration. Profile
    // updates outside this gate are reserved for the manual calibration
    // overlay (`_completeCurlCalibration`).
    if (_autoCalibrationEnabled) {
      _autoCalibrator.recordRepExtremes(minAngle, maxAngle);
    }
    final profile = _profile;
    if (profile == null) return;
    RepApplyResult? result;
    RomBucket? mutatedBucket;
    if (_autoCalibrationEnabled) {
      final bucket =
          profile.bucketFor(side, view) ?? RomBucket.empty(side, view);
      result = bucket.applyRep(minAngle, maxAngle);
      profile.upsertBucket(bucket);
      _profileDirty = true;
      mutatedBucket = bucket;
    }

    // Re-resolve the source the FSM would have used for this rep. The
    // resolver is pure, so calling it here yields the same source the engine
    // locked at IDLE→CONCENTRIC (no mid-rep swap per plan invariant 4).
    final resolved = _resolveThresholds(side, view, _snapshot.reps);
    _curlRepRecords.add(
      CurlRepRecord(
        repIndex: _curlRepRecords.length + 1,
        side: side,
        view: view,
        minAngle: minAngle,
        maxAngle: maxAngle,
        source: resolved.source,
        bucketUpdated:
            result == RepApplyResult.applied ||
            result == RepApplyResult.initialized,
        rejectedOutlier: result == RepApplyResult.rejectedOutlier,
      ),
    );
    // Index-aligned with `_curlRepRecords`; consumed by
    // `_persistCompletedSession` → `SqliteSessionRepository`.
    _repConcentricDurations.add(concentricDuration);

    // Side-view per-rep telemetry snapshot. Read straight off the umbrella
    // `formExtras` — the side analyzer has populated the four maxes during
    // the rep and `onRepEnd()` left them intact for read-out. Front-view
    // and front-curl-with-asymmetric-commit reps fall through (the front
    // analyzer's stub getters return 0.0 / null), and the persistence path
    // gates on `ExerciseType.bicepsCurlSide` before reading these out, so
    // the noise stays out of the wire format.
    if (exercise == ExerciseType.bicepsCurlSide &&
        (view == CurlCameraView.sideLeft || view == CurlCameraView.sideRight)) {
      final extras = _repCounter.curlFormExtras;
      if (extras != null) {
        _bicepsSideRepMetrics.add(
          BicepsSideRepMetrics(
            repIndex: _bicepsSideRepMetrics.length + 1,
            leanDeg: extras.maxTorsoLeanDegThisRep,
            shoulderDriftRatio: extras.maxShoulderDriftRatioThisRep,
            elbowDriftRatio: extras.maxElbowDriftRatioThisRep,
            backLeanDeg: extras.maxBackLeanDegThisRep,
            elbowDriftSigned: extras.signedElbowDriftRatioAtMax,
            shrugRatio: extras.maxShrugRatioThisRep,
            elbowRiseRatio: extras.maxElbowRiseRatioThisRep,
          ),
        );
      }
    }

    // `profile.update` fires only when the live path actually wrote to the
    // bucket. Under the calibration-opt-in contract (auto-cal OFF) the bucket
    // is untouched here and the log line would be a meaningless echo, so we
    // skip it. Manual calibration completion emits `calibration.complete`
    // separately as the canonical write-event for the overlay path.
    if (result != null && mutatedBucket != null) {
      TelemetryLog.instance.log(
        'profile.update',
        'side=${side.name} view=${view.name} result=${result.name} '
            'samples=${mutatedBucket.sampleCount} '
            'min=${mutatedBucket.observedMinAngle.toStringAsFixed(1)} '
            'max=${mutatedBucket.observedMaxAngle.toStringAsFixed(1)}',
      );
    }

    // Raw per-rep extremes — the un-smoothed angles this rep actually hit.
    // Distinct from `profile.update` above (which logs the EMA-smoothed
    // bucket). This is the line to paste back when re-deriving global
    // defaults: fixed-order key=value tokens so regex parsing is trivial.
    // `source` exposes which threshold path this rep ran under so reps that
    // ran on the very defaults we're trying to replace can be filtered out.
    TelemetryLog.instance.log(
      'rep.extremes',
      'rep=${_curlRepRecords.length} '
          'side=${side.name} '
          'view=${view.name} '
          'min=${minAngle.toStringAsFixed(1)} '
          'max=${maxAngle.toStringAsFixed(1)} '
          'rom=${(maxAngle - minAngle).toStringAsFixed(1)} '
          'min_at_peak=${minAtPeak?.toStringAsFixed(1) ?? "null"} '
          'concentric_ms=${concentricDuration?.inMilliseconds ?? -1} '
          'source=${resolved.source.name} '
          'result=${result?.name ?? "skipped"}',
    );

    // Side-view form telemetry — the second canonical paste-back line.
    // Fixed-order key=value tokens, same parser shape as `rep.extremes`.
    // Emitted only on side-view biceps reps so the log doesn't fill with
    // zeros from front-view / squat / push-up reps. Joins `rep.extremes`
    // by `rep=N`. Token meanings:
    //
    //   lean_deg                — peak forward-lean delta (degrees)
    //   shoulder_drift_ratio    — peak |Δ(shoulder − hip)| / torso_len
    //   elbow_drift_ratio       — peak |perp(E − S, n̂)| / torso_len
    //   elbow_drift_signed      — same projection at the peak frame, with
    //                             sign preserved (split forward vs back)
    //   back_lean_deg           — peak hyperextension (degrees)
    //   shrug_ratio             — peak −Δ(shoulder.y − hip.y) / torso_len
    //                             (positive = shoulder rose). Retunes
    //                             `kShrugThreshold` from real distributions.
    //   elbow_rise_ratio        — peak (baseline_elbowRelY − current) /
    //                             torso_len (positive = elbow swung up,
    //                             front-delt cheat). Retunes
    //                             `kElbowRiseThreshold`.
    //   rep_quality             — analyzer's lastRepQuality (0.0–1.0).
    //                             Filter clean-form reps by quality > 0.85
    //                             when computing percentile thresholds.
    //   source                  — global / warmup / calibrated /
    //                             autoCalibrated. Drop reps whose source
    //                             matches the path being retuned.
    //   concentric_ms           — duplicates `rep.extremes` for self-contained
    //                             rows (so the side-form log is independently
    //                             grep-able without joining back).
    if (exercise == ExerciseType.bicepsCurlSide &&
        (view == CurlCameraView.sideLeft || view == CurlCameraView.sideRight)) {
      final extras = _repCounter.curlFormExtras;
      if (extras != null) {
        // Side-mismatch diagnostic line. Emitted BEFORE `rep.side_metrics`
        // so that when a user reports "I picked left but the log says
        // right," this single line shows exactly why:
        //
        //   declared_side       — what the user tapped at home screen
        //                         (mapped from `ExerciseSide` →
        //                         `ProfileSide` via `_profileSideForRep`).
        //   declared_view       — the locked camera view (echoes the
        //                         home-screen tap for pre-seeded
        //                         sessions; that's a tautology, but
        //                         making it explicit prevents readers
        //                         from interpreting it as detection).
        //   resolved_arm        — what `_resolveActiveArm` picked from
        //                         per-arm landmark confidence sums.
        //   committed_side      — what `_commitRepSamples` actually
        //                         wrote to the rep record. After the
        //                         Bug 3 fix this should equal
        //                         `resolved_arm` whenever any landmark
        //                         confidence was non-zero.
        //   left_conf / right_conf — the inputs `_resolveActiveArm`
        //                         summed (shoulder + hip + elbow per
        //                         side). Both ≈ 0.0 → the analyzer
        //                         fell back to the declared view.
        //   pose_facing         — `_facingRight` from nose-vs-shoulder
        //                         X comparison. "right" = user's nose
        //                         is on the camera-right of the active
        //                         shoulder. Compare with `declared_view`:
        //                         if declared sideLeft but pose_facing=right,
        //                         the camera was framing the wrong side.
        //   arm_match           — boolean shortcut: did declared_side
        //                         agree with resolved_arm? Quick filter
        //                         for "show me the mismatched reps."
        final declaredArmIsLeft = side == ProfileSide.left;
        final resolvedArmIsLeft = extras.activeArmIsLeftThisRep;
        final armMatch = declaredArmIsLeft == resolvedArmIsLeft;
        final poseFacing = extras.facingRightThisRep == null
            ? 'unknown'
            : (extras.facingRightThisRep! ? 'right' : 'left');
        TelemetryLog.instance.log(
          'rep.arm_resolved',
          'rep=${_curlRepRecords.length} '
              'declared_side=${declaredArmIsLeft ? "left" : "right"} '
              'declared_view=${view.name} '
              'resolved_arm=${resolvedArmIsLeft ? "left" : "right"} '
              'committed_side=${side.name} '
              'left_conf=${extras.leftArmConfidenceSumThisRep.toStringAsFixed(2)} '
              'right_conf=${extras.rightArmConfidenceSumThisRep.toStringAsFixed(2)} '
              'pose_facing=$poseFacing '
              'arm_match=$armMatch',
        );
        TelemetryLog.instance.log(
          'rep.side_metrics',
          'rep=${_curlRepRecords.length} '
              'side=${side.name} '
              'view=${view.name} '
              'lean_deg=${extras.maxTorsoLeanDegThisRep.toStringAsFixed(2)} '
              'shoulder_drift_ratio=${extras.maxShoulderDriftRatioThisRep.toStringAsFixed(4)} '
              'elbow_drift_ratio=${extras.maxElbowDriftRatioThisRep.toStringAsFixed(4)} '
              'elbow_drift_signed=${extras.signedElbowDriftRatioAtMax?.toStringAsFixed(4) ?? "null"} '
              'back_lean_deg=${extras.maxBackLeanDegThisRep.toStringAsFixed(2)} '
              'shrug_ratio=${extras.maxShrugRatioThisRep.toStringAsFixed(4)} '
              'elbow_rise_ratio=${extras.maxElbowRiseRatioThisRep.toStringAsFixed(4)} '
              'rep_quality=${extras.lastRepQuality.toStringAsFixed(3)} '
              'concentric_ms=${concentricDuration?.inMilliseconds ?? -1} '
              'source=${resolved.source.name}',
        );
      }
    }
  }

  /// Periodic frame-level telemetry for curl debug sessions. Captures the
  /// data we lose between rep commits: per-arm landmark confidences (so we
  /// can see WHY the FSM never armed), the current FSM state, the elbow
  /// angle, and torso length. Emitted at ~`kDebugFrameMetricsHz` Hz from
  /// the active-phase frame loop.
  ///
  /// Token vocabulary (fixed-order, key=value, regex-friendly):
  ///   fsm                  — RepState (idle / concentric / peak / eccentric)
  ///   angle                — primary joint angle this frame (degrees) or "null"
  ///   l_sh / l_el / l_wr / l_hip — left-side landmark confidences
  ///   r_sh / r_el / r_wr / r_hip — right-side landmark confidences
  ///   torso_len            — `verticalDist(shoulder, hip)` for the active arm,
  ///                          or "null" if landmarks missing
  ///
  /// Confidences below `kMinLandmarkConfidence` are NOT gated out — the
  /// whole point is to expose the raw signal that drives `_resolveActiveArm`
  /// and the FSM's landmark-availability decisions.
  void _emitDebugFrameMetrics(PoseResult result, RepSnapshot snapshot) {
    double conf(int landmarkType) {
      for (final lm in result.landmarks) {
        if (lm.type == landmarkType) return lm.confidence;
      }
      return 0.0;
    }

    final angle = snapshot.jointAngle;
    final angleStr = angle == null ? 'null' : angle.toStringAsFixed(1);
    TelemetryLog.instance.log(
      'pose.frame_metrics',
      'fsm=${snapshot.state.name} '
          'angle_raw=$angleStr ' // unsmoothed; FSM gates on 3-frame moving average
          'l_sh=${conf(LM.leftShoulder).toStringAsFixed(2)} '
          'l_el=${conf(LM.leftElbow).toStringAsFixed(2)} '
          'l_wr=${conf(LM.leftWrist).toStringAsFixed(2)} '
          'l_hip=${conf(LM.leftHip).toStringAsFixed(2)} '
          'r_sh=${conf(LM.rightShoulder).toStringAsFixed(2)} '
          'r_el=${conf(LM.rightElbow).toStringAsFixed(2)} '
          'r_wr=${conf(LM.rightWrist).toStringAsFixed(2)} '
          'r_hip=${conf(LM.rightHip).toStringAsFixed(2)}',
    );
  }

  /// Periodic frame-level telemetry for squat debug sessions.
  /// Throttled to [kSquatDebugFrameMetricsHz]. Emits hip/knee/ankle
  /// landmark confidences + FSM state + primary joint angle.
  void _emitSquatDebugFrameMetrics(PoseResult result, RepSnapshot snapshot) {
    double conf(int type) {
      for (final lm in result.landmarks) {
        if (lm.type == type) return lm.confidence;
      }
      return 0.0;
    }

    final angle = snapshot.jointAngle;
    TelemetryLog.instance.log(
      'squat.frame_metrics',
      'fsm=${snapshot.state.name} '
          'angle=${angle == null ? "null" : angle.toStringAsFixed(1)} '
          'l_hip=${conf(LM.leftHip).toStringAsFixed(2)} '
          'l_knee=${conf(LM.leftKnee).toStringAsFixed(2)} '
          'l_ankle=${conf(LM.leftAnkle).toStringAsFixed(2)} '
          'r_hip=${conf(LM.rightHip).toStringAsFixed(2)} '
          'r_knee=${conf(LM.rightKnee).toStringAsFixed(2)} '
          'r_ankle=${conf(LM.rightAnkle).toStringAsFixed(2)}',
    );
  }

  List<CurlProfileBucketSummary> _snapshotBucketsForSummary() {
    final profile = _profile;
    if (profile == null) return const [];
    final touchedKeys = _curlRepRecords
        .map((r) => RomBucket.keyFor(r.side, r.view))
        .toSet();
    final sessionRepsPerBucket = <String, int>{};
    for (final r in _curlRepRecords) {
      final k = RomBucket.keyFor(r.side, r.view);
      sessionRepsPerBucket[k] = (sessionRepsPerBucket[k] ?? 0) + 1;
    }
    return profile.buckets.values.map((b) {
      return CurlProfileBucketSummary(
        side: b.side,
        view: b.view,
        observedMinAngle: b.observedMinAngle,
        observedMaxAngle: b.observedMaxAngle,
        sampleCount: b.sampleCount,
        lastUpdated: b.lastUpdated,
        isCalibrated: profile.isCalibrated(b.side, b.view),
        sessionReps: touchedKeys.contains(b.key)
            ? (sessionRepsPerBucket[b.key] ?? 0)
            : 0,
      );
    }).toList();
  }

  /// Per-rep depth as a fraction of the user's reference range. Currently
  /// only curl sessions capture per-rep ROM live (`_curlRepRecords`); squat
  /// and push-up commit handlers don't surface min/max angles to the VM, so
  /// they return an empty list here. Reconstructed-from-DB sessions get
  /// richer treatment in `SummaryScreen.fromSession` where `RepRow` exposes
  /// min/max for any exercise.
  ///
  /// Reference range per rep is the calibrated bucket's peak ROM when the
  /// matching `(side, view)` bucket is calibrated; otherwise it falls back
  /// to the session's max observed ROM. Returns `null` for an individual
  /// rep when neither reference is available (rejected outliers, abandoned
  /// reps with zero ROM).
  List<double?> _computeLiveRepDepthPercents() {
    if (_curlRepRecords.isEmpty) return const [];
    final profile = _profile;
    final sessionMaxRom = _curlRepRecords
        .map((r) => r.romDegrees)
        .fold<double>(0, (a, b) => a > b ? a : b);
    return _curlRepRecords
        .map<double?>((r) {
          double? reference;
          final bucket = profile?.bucketFor(r.side, r.view);
          final bucketRom = bucket == null
              ? 0.0
              : bucket.observedMaxAngle - bucket.observedMinAngle;
          if (bucket != null &&
              (profile?.isCalibrated(r.side, r.view) ?? false) &&
              bucketRom > 0) {
            reference = bucketRom;
          } else if (sessionMaxRom > 0) {
            reference = sessionMaxRom;
          }
          if (reference == null || reference <= 0) return null;
          final pct = r.romDegrees / reference;
          return pct.clamp(0.0, 1.0);
        })
        .toList(growable: false);
  }

  Future<void> _flushProfileIfDirty() async {
    if (!_profileDirty || _profile == null) return;
    try {
      await _profileRepository.saveCurl(_profile!);
      _profileDirty = false;
    } catch (e) {
      TelemetryLog.instance.log('profile.save_failed', e.toString());
    }
  }

  Future<void> _flushSquatProfileIfDirty() async {
    if (!_squatProfileDirty || _squatProfile == null) return;
    try {
      await _profileRepository.saveSquat(_squatProfile!);
      _squatProfileDirty = false;
    } catch (e) {
      TelemetryLog.instance.log('squat_profile.save_failed', e.toString());
    }
  }

  // ── Calibration phase ─────────────────────────────────
  void _enterCalibration() {
    _phase = WorkoutPhase.calibration;
    _calibrationReps = 0;
    _calibrationSecondsRemaining = kCalibrationTimeoutSec;
    _calibrationError = null;
    _calibrationCurrentAngle = null;
    _calibrationCollected.clear();
    _resetPushUpCalibrationState();
    if (exercise == ExerciseType.pushUp) {
      TelemetryLog.instance.log('pushup_calibration.start', 'phase entered');
      _tts.speak('Hold the top push-up position with your body straight.');
      _startCalibrationTimeout();
      notifyListeners();
      return;
    }
    if (exercise == ExerciseType.squat) {
      // Squat reuses the curl `RepBoundaryDetector` as-is — its smoothing
      // and direction-confirmation gates work on any monotonic joint
      // angle (knee vs elbow), and the per-rep min/max it emits map
      // cleanly to the squat ROM bucket. The accept-rep gate is
      // squat-specific (`kSquatMinViableRomDegrees`, applied in
      // `_onCalibrationRep`).
      _calibrationDetector = RepBoundaryDetector();
      _calibrationSub = _calibrationDetector!.extremes.listen(
        _onCalibrationRep,
      );
      TelemetryLog.instance.log('squat.calibration.start', 'phase entered');
      _tts.speak(
        'Squat through your full natural range, '
        '$kSquatCalibrationMinReps times.',
      );
      _startCalibrationTimeout();
      notifyListeners();
      return;
    }
    // Curl: defer detector arming + timeout until the user picks Left/Right
    // in the side-pick panel. The overlay renders the picker when
    // `calibrationChosenSide == null`; `pickCalibrationSide()` then arms
    // the detector and starts the timeout. This lets the user read the
    // prompt without the timeout already eating into their session.
    //
    // 2026-05-15 fast-path: when the caller (home-screen tile OR Settings
    // recalibrate) has already committed to a side via [curlSide], skip the
    // in-overlay picker and arm the detector immediately. Without this the
    // user picks twice (home → "Right" → calibration → "Right" again), and
    // — worse — the Settings path used to default to ExerciseSide.both and
    // let the analyzer pick by landmark confidence, which consistently
    // chose the right arm regardless of user intent.
    //
    // `curlSide` is camera-frame (ExerciseSide.right = right side of frame
    // = user's physical LEFT arm). `_profileSideForCalibration` applies the
    // identical mapping used inside `CurlStrategy._profileSideForRep` so
    // the calibration bucket key matches the workout-side bucket key.
    final preChosenSide = _profileSideForCalibration(curlSide);
    if (preChosenSide != null) {
      _calibrationChosenSide = preChosenSide;
      _calibrationDetector = RepBoundaryDetector();
      _calibrationSub = _calibrationDetector!.extremes.listen(
        _onCalibrationRep,
      );
      TelemetryLog.instance.log(
        'calibration.start',
        'phase entered preChosenSide=${preChosenSide.name} '
            'source=curlSide(${curlSide.name})',
      );
      _tts.speak(
        'Curl through your full natural range, $kCalibrationMinReps times.',
      );
      _startCalibrationTimeout();
      notifyListeners();
      return;
    }
    TelemetryLog.instance.log(
      'calibration.start',
      'phase entered awaiting_side_pick=true',
    );
    notifyListeners();
  }

  /// Camera-frame [ExerciseSide] → user-frame [ProfileSide] for calibration
  /// bucket keying. Returns null for [ExerciseSide.both], which means "no
  /// pre-pick" and the in-overlay picker remains the source of truth.
  ///
  /// Mirrors `CurlStrategy._profileSideForRep` exactly — both must apply
  /// the same convention or the calibration bucket the user creates won't
  /// be the bucket the workout reads later.
  ProfileSide? _profileSideForCalibration(ExerciseSide side) => switch (side) {
    ExerciseSide.left => ProfileSide.left,
    ExerciseSide.right => ProfileSide.right,
    ExerciseSide.both => null,
  };

  void _startCalibrationTimeout() {
    _calibrationTimeoutTimer?.cancel();
    _calibrationTimeoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _calibrationSecondsRemaining--;
      notifyListeners();
      if (_calibrationSecondsRemaining <= 0) {
        t.cancel();
        final message = exercise == ExerciseType.pushUp
            ? "Couldn't complete calibration — try again or skip."
            : "Didn't see any reps — try again or skip.";
        _failCalibration(message);
      }
    });
  }

  void _resetPushUpCalibrationState() {
    _pushUpCalibrationStage = _PushUpCalibrationStage.observeReps;
    _pushUpCalibrationRepDetector.reset();
    _pushUpCalibrationTopSamples.clear();
    _pushUpCalibrationBottomSamples.clear();
    _pushUpCalibrationTopAngle = null;
    _pushUpCalibrationInstruction =
        'Do 3 controlled push-ups at your normal tempo.';
  }

  void _onCalibrationRep(RepExtreme rep) {
    if (exercise == ExerciseType.squat) {
      // Squat-specific viability gate. The boundary detector already
      // applies `kCalibrationMinExcursion` (40°) at its emit gate, but
      // we apply the named-for-squat threshold explicitly here so a
      // future divergence (lifting `kCalibrationMinExcursion` while
      // keeping squat at 40°) just works without re-plumbing the
      // detector. Rejected reps don't bump the counter — they vanish
      // silently, mirroring how the detector drops sub-excursion reps.
      final rom = (rep.maxAngle - rep.minAngle).abs();
      if (rom < kSquatMinViableRomDegrees) return;
      _calibrationCollected.add(rep);
      _calibrationReps = _calibrationCollected.length;
      notifyListeners();
      if (_calibrationReps >= kSquatCalibrationMinReps) {
        _completeSquatCalibration();
      }
      return;
    }
    _calibrationCollected.add(rep);
    _calibrationReps = _calibrationCollected.length;
    notifyListeners();
    if (_calibrationReps >= kCalibrationMinReps) _completeCalibration();
  }

  void _completeCalibration() {
    _calibrationTimeoutTimer?.cancel();
    final chosenSide = _calibrationChosenSide;
    if (chosenSide == null) {
      // Defensive: detector should never emit before pickCalibrationSide()
      // runs (the detector isn't created until then). If we ever get here
      // it's a bug — fail loudly rather than guess a side.
      _failCalibration('Calibration completed before a side was picked.');
      return;
    }
    // `view` keys the bucket alongside `side`. The detector's auto-view is
    // also what `_resolveThresholds` uses at workout time, so we MUST agree
    // with it here for the calibrated bucket to be found later. If the
    // detector hasn't locked a side-view (still `unknown` or fell back to
    // `front`), derive it from the user's pick — better a coherent storage
    // key than a degenerate one. This is the fallback only; under normal
    // operation `_detectedCurlView` is already locked by setupCheck.
    var lockedView = _detectedCurlView;
    if (lockedView == CurlCameraView.unknown ||
        lockedView == CurlCameraView.front) {
      lockedView = chosenSide == ProfileSide.left
          ? CurlCameraView.sideLeft
          : CurlCameraView.sideRight;
    }
    final avgMin =
        _calibrationCollected.map((r) => r.minAngle).reduce((a, b) => a + b) /
        _calibrationCollected.length;
    final avgMax =
        _calibrationCollected.map((r) => r.maxAngle).reduce((a, b) => a + b) /
        _calibrationCollected.length;

    if ((avgMax - avgMin) < kMinViableRomDegrees) {
      _failCalibration(
        'Range too small (${(avgMax - avgMin).toStringAsFixed(0)}°). '
        'Use your full motion.',
      );
      return;
    }

    final profile = _profile ?? CurlRomProfile();
    // Single chosen-side flow: build (or extend) the bucket for
    // `(chosenSide, lockedView)` from collected reps, then — on the first
    // pass only and only if it wouldn't overwrite an already-calibrated
    // opposite-side bucket — duplicate it to the other side so both arms
    // resolve to calibrated thresholds in workouts (Global Calibration).
    final chosenBucket = profile.bucketOrEmpty(chosenSide, lockedView);
    for (final rep in _calibrationCollected) {
      chosenBucket.applyRep(rep.minAngle, rep.maxAngle);
    }
    profile.upsertBucket(chosenBucket);

    var duplicatedToOther = false;
    if (_shouldDuplicateToOtherSide(chosenSide, lockedView)) {
      final otherSide = chosenSide == ProfileSide.left
          ? ProfileSide.right
          : ProfileSide.left;
      final clone = _cloneBucketForOtherSide(chosenBucket, otherSide);
      profile.upsertBucket(clone);
      duplicatedToOther = true;
    }

    _profile = profile;
    _profileDirty = true;
    TelemetryLog.instance.log(
      'calibration.complete',
      'view=${lockedView.name} side=${chosenSide.name} '
          'duplicated_to_other=$duplicatedToOther '
          'avgMin=${avgMin.toStringAsFixed(1)} '
          'avgMax=${avgMax.toStringAsFixed(1)}',
    );
    _flushProfileIfDirty();

    final viewLabel = switch (lockedView) {
      CurlCameraView.front => 'Front view',
      CurlCameraView.sideLeft => 'Left-side view',
      CurlCameraView.sideRight => 'Right-side view',
      CurlCameraView.unknown => 'Detected view',
    };
    final sidesLabel = duplicatedToOther
        ? '${chosenSide == ProfileSide.left ? "Left" : "Right"} arm '
              '(applied to both)'
        : '${chosenSide == ProfileSide.left ? "Left" : "Right"} arm';
    _calibrationSummary = CalibrationSummary(
      viewLabel: viewLabel,
      sidesLabel: sidesLabel,
    );

    // Scope is now auto-derived from the data, not asked of the user:
    //   - One arm calibrated  → `_shouldDuplicateToOtherSide` cloned the
    //     bucket above → effectively *global*.
    //   - Both arms previously calibrated → the duplicate guard refused
    //     → the existing opposite-side bucket is preserved → *per-side*.
    // The legacy "Calibrate the other arm too? Yes / No use globally"
    // prompt was redundant UX — both outcomes are derivable from the
    // profile state. Auto-dismiss the summary after 2 s on every pass.
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      _calibrationSummary = null;
      // Settings → Recalibrate path: the user came specifically to calibrate,
      // not to start a workout. Flag the screen to pop back to where they
      // came from instead of advancing into setupCheck → countdown → active.
      // Calibration resources are released here too so the camera/pose stream
      // shut down cleanly before the screen pops.
      if (forceCalibration) {
        _disposeCalibrationResources();
        _shouldExitAfterCalibration = true;
        notifyListeners();
        return;
      }
      _exitCalibration(toPhase: WorkoutPhase.setupCheck);
    });
  }

  /// Squat calibration completion. Mirrors `_completeCalibration` but
  /// targets `SquatRomProfile` instead of `CurlRomProfile`, and there's
  /// no `(side, view)` axis to seed — squat has one bucket per user.
  ///
  /// Persists via `_profileRepository.saveSquat`. The save is awaited
  /// inside a fire-and-forget block so a slow disk write doesn't block
  /// the 2s summary card. Failures are non-fatal — the in-memory
  /// `_squatProfile` is still set, so the current session can use it,
  /// and the dispose-time flush will retry the write.
  void _completeSquatCalibration() {
    _calibrationTimeoutTimer?.cancel();

    final avgMin =
        _calibrationCollected.map((r) => r.minAngle).reduce((a, b) => a + b) /
        _calibrationCollected.length;
    final avgMax =
        _calibrationCollected.map((r) => r.maxAngle).reduce((a, b) => a + b) /
        _calibrationCollected.length;

    // Belt-and-suspenders ROM check — `_onCalibrationRep` already gated
    // each rep at `kSquatMinViableRomDegrees`, but averaging the
    // collected reps could in principle still slip below the bar if the
    // detector emitted a borderline-passing rep alongside others.
    if ((avgMax - avgMin) < kSquatMinViableRomDegrees) {
      _failCalibration(
        'Range too small (${(avgMax - avgMin).toStringAsFixed(0)}°). '
        'Use your full motion.',
      );
      return;
    }

    // Seed (or extend) the squat bucket with every collected rep.
    final profile = _squatProfile ?? squat_profile.SquatRomProfile();
    final bucket = profile.bucket ?? squat_profile.SquatRomBucket.empty();
    for (final rep in _calibrationCollected) {
      bucket.applyRep(rep.minAngle, rep.maxAngle);
    }
    profile.bucket = bucket;
    _squatProfile = profile;
    _squatProfileDirty = true;

    TelemetryLog.instance.log(
      'squat.calibration.complete',
      'reps=${_calibrationCollected.length} '
          'avgMin=${avgMin.toStringAsFixed(1)} '
          'avgMax=${avgMax.toStringAsFixed(1)} '
          'samples=${bucket.sampleCount}',
    );
    unawaited(_flushSquatProfileIfDirty());

    _calibrationSummary = CalibrationSummary(
      viewLabel: 'Squat ROM',
      sidesLabel:
          'Bottom ${avgMin.toStringAsFixed(0)}° · '
          'Top ${avgMax.toStringAsFixed(0)}°',
    );
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      _calibrationSummary = null;
      if (forceCalibration) {
        _disposeCalibrationResources();
        _shouldExitAfterCalibration = true;
        notifyListeners();
        return;
      }
      _exitCalibration(toPhase: WorkoutPhase.setupCheck);
    });
  }

  void _failCalibration(String reason) {
    _calibrationTimeoutTimer?.cancel();
    // Free the boundary-detector stream subscription + detector itself.
    // Without this, a failed calibration would leak both — the stream
    // sub never closes until `retryCalibration()` or `skipCalibration()`
    // fires, and a user who closes the workout from the error banner
    // would carry orphaned resources for the rest of the session.
    // Mirrors the cleanup that `_exitCalibration` already performs on
    // the happy path.
    _calibrationSub?.cancel();
    _calibrationSub = null;
    _calibrationDetector?.dispose();
    _calibrationDetector = null;
    // Squat uses a dedicated telemetry tag so the dataset-analysis
    // workflow can filter by exercise without parsing the message body.
    final tag = exercise == ExerciseType.squat
        ? 'squat.calibration.fail'
        : 'calibration.fail';
    TelemetryLog.instance.log(tag, reason);
    _calibrationError = reason;
    notifyListeners();
  }

  void retryCalibration() {
    _disposeCalibrationResources();
    _calibrationChosenSide = null;
    _enterCalibration();
  }

  void skipCalibration() {
    TelemetryLog.instance.log('calibration.skipped', 'user opted out');
    _exitCalibration(toPhase: WorkoutPhase.setupCheck);
  }

  // ── Curl side-pick contract ───────────────────────────────
  //
  // Calibration for biceps curl is single-pass: the user taps Left or
  // Right at the start, the chosen-side bucket is built from collected
  // reps, and — if no calibrated opposite-side bucket already exists —
  // the result is duplicated to the other side so both arms resolve to
  // calibrated thresholds (effective "global" behavior). If the opposite
  // side is already calibrated, the duplicate guard preserves it and the
  // calibration becomes "per-side." The user therefore never needs to
  // choose scope explicitly — the data answers it.
  //
  // To calibrate the second arm with its own data, the user re-enters
  // calibration from Settings and picks the other side.
  ProfileSide? _calibrationChosenSide;

  ProfileSide? get calibrationChosenSide => _calibrationChosenSide;

  /// Called when the user taps Left or Right in the side-pick panel.
  /// Arms the [RepBoundaryDetector] and starts the calibration timeout —
  /// both are deferred until this point so the user can take their time
  /// reading the prompt without the countdown ticking.
  void pickCalibrationSide(ProfileSide side) {
    if (!exercise.isCurl) return;
    if (_phase != WorkoutPhase.calibration) return;
    if (_calibrationChosenSide != null) return; // idempotent
    _calibrationChosenSide = side;
    _calibrationDetector = RepBoundaryDetector();
    _calibrationSub = _calibrationDetector!.extremes.listen(_onCalibrationRep);
    TelemetryLog.instance.log('calibration.side_picked', 'side=${side.name}');
    _tts.speak(
      'Curl through your full natural range, $kCalibrationMinReps times.',
    );
    _startCalibrationTimeout();
    notifyListeners();
  }

  /// True iff duplicating the just-saved bucket into the opposite side
  /// would not overwrite an already-calibrated bucket. Protects a prior
  /// dedicated calibration of the opposite side from being silently
  /// replaced when the user later recalibrates only one side.
  bool _shouldDuplicateToOtherSide(ProfileSide chosen, CurlCameraView view) {
    final profile = _profile;
    if (profile == null) return true;
    final other = chosen == ProfileSide.left
        ? ProfileSide.right
        : ProfileSide.left;
    final existing = profile.bucketFor(other, view);
    return (existing?.sampleCount ?? 0) < kCalibrationMinReps;
  }

  /// Deep-copy of a bucket. JSON round-trip is the cheapest correct
  /// snapshot — `RomBucket.fromJson` reconstructs all internal state
  /// (recent-sample lists, shrink counters, timestamps), and the lists
  /// inside the source bucket are not aliased into the copy.
  RomBucket _cloneBucketForOtherSide(RomBucket source, ProfileSide otherSide) {
    final json =
        jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;
    json['side'] = otherSide.name;
    return RomBucket.fromJson(json);
  }

  void _exitCalibration({required WorkoutPhase toPhase}) {
    _disposeCalibrationResources();
    _phase = toPhase;
    _setupOkFrames = 0;
    notifyListeners();
  }

  void _disposeCalibrationResources() {
    _calibrationTimeoutTimer?.cancel();
    _calibrationTimeoutTimer = null;
    _calibrationSub?.cancel();
    _calibrationSub = null;
    _calibrationDetector?.dispose();
    _calibrationDetector = null;
    _pushUpCalibrationRepDetector.reset();
    _pushUpCalibrationTopSamples.clear();
    _pushUpCalibrationBottomSamples.clear();
  }

  /// Hole #1 trigger: called whenever `_detectedCurlView` flips to a non-unknown
  /// value during ACTIVE play. If the new view's bucket has fewer than the
  /// calibration minimum, show a 2s passive banner.
  void _maybeShowUncalibratedNotice(CurlCameraView newView) {
    if (!exercise.isCurl) return;
    if (newView == CurlCameraView.unknown) return;
    if (_phase != WorkoutPhase.active) return;
    final profile = _profile;
    if (profile == null) return;
    final sidesToCheck = switch (newView) {
      CurlCameraView.front => const [ProfileSide.left, ProfileSide.right],
      CurlCameraView.sideLeft => const [ProfileSide.left],
      CurlCameraView.sideRight => const [ProfileSide.right],
      CurlCameraView.unknown => const <ProfileSide>[],
    };
    final anyCalibrated = sidesToCheck.any((s) {
      final b = profile.bucketFor(s, newView);
      return b != null && b.sampleCount >= kCalibrationMinReps;
    });
    if (anyCalibrated) return;
    final label = switch (newView) {
      CurlCameraView.front => 'Front view',
      CurlCameraView.sideLeft => 'Left-side view',
      CurlCameraView.sideRight => 'Right-side view',
      CurlCameraView.unknown => '',
    };
    _uncalibratedNoticeTimer?.cancel();
    _uncalibratedViewNotice =
        '$label uncalibrated — first reps use generic thresholds';
    notifyListeners();
    TelemetryLog.instance.log(
      'view.uncalibrated_notice',
      'view=${newView.name}',
    );
    _uncalibratedNoticeTimer = Timer(const Duration(seconds: 2), () {
      _uncalibratedViewNotice = null;
      notifyListeners();
    });
  }

  void _updateCalibration(PoseResult result, List<PoseLandmark> smoothed) {
    if (exercise == ExerciseType.pushUp) {
      _updatePushUpCalibration(result, smoothed);
      return;
    }

    if (exercise == ExerciseType.squat) {
      // Knee angle drives the detector here. The detector tracks raw
      // extremes — min during descent (deepest knee flexion) and max
      // during ascent (standing extension) — which map directly to the
      // `SquatRomBucket` extremes the calibration commit needs. Reuse
      // the strategy's `computePrimaryAngle` so the same picking rule
      // (averaging two sides when both available) used in the active
      // FSM is also used in calibration.
      final angle = _repCounter.computeSquatPrimaryAngle(result);
      if (angle != null) _calibrationDetector?.onAngle(angle);
      _landmarks = smoothed;
      _calibrationCurrentAngle = angle;
      notifyListeners();
      return;
    }

    final view = _repCounter.updateSetupView(result);
    if (view != _detectedCurlView) _detectedCurlView = view;

    // Side-aware elbow-angle selection (2026-05-15).
    //
    // Pre-2026-05-15 this was `leftElbow ?? rightElbow`, which silently fell
    // through to the right arm whenever the left arm's landmarks were
    // momentarily missing — and in a typical side-view recording one arm is
    // ALWAYS partially occluded by the torso, so the fall-through path was
    // effectively the default. Net effect: even when the user explicitly
    // picked "Left", calibration kept measuring the right arm.
    //
    // New convention: once the user has committed to a side, prefer that
    // side's elbow angle. If that side's landmarks are unavailable on a
    // given frame, fall through to the opposite arm rather than dropping
    // the frame — this preserves calibration throughput on noisy frames
    // while keeping the dominant signal anchored to the chosen arm. The
    // detector's 3-sample direction-confirmation gate handles per-frame
    // jitter from the fallback path.
    //
    // When no side is picked yet (`_calibrationChosenSide == null`, in-overlay
    // picker still up) the prior left-first behavior is retained so the live
    // angle display has something to render while the user reads the prompt.
    final chosen = _calibrationChosenSide;
    final double? angle;
    if (chosen == ProfileSide.left) {
      angle =
          angleDeg(
            result.landmark(LM.leftShoulder),
            result.landmark(LM.leftElbow),
            result.landmark(LM.leftWrist),
          ) ??
          angleDeg(
            result.landmark(LM.rightShoulder),
            result.landmark(LM.rightElbow),
            result.landmark(LM.rightWrist),
          );
    } else if (chosen == ProfileSide.right) {
      angle =
          angleDeg(
            result.landmark(LM.rightShoulder),
            result.landmark(LM.rightElbow),
            result.landmark(LM.rightWrist),
          ) ??
          angleDeg(
            result.landmark(LM.leftShoulder),
            result.landmark(LM.leftElbow),
            result.landmark(LM.leftWrist),
          );
    } else {
      angle =
          angleDeg(
            result.landmark(LM.leftShoulder),
            result.landmark(LM.leftElbow),
            result.landmark(LM.leftWrist),
          ) ??
          angleDeg(
            result.landmark(LM.rightShoulder),
            result.landmark(LM.rightElbow),
            result.landmark(LM.rightWrist),
          );
    }

    if (angle != null) _calibrationDetector?.onAngle(angle);
    _landmarks = smoothed;
    _calibrationCurrentAngle = angle;
    notifyListeners();
  }

  void _updatePushUpCalibration(
    PoseResult result,
    List<PoseLandmark> smoothed,
  ) {
    final angle = _pushUpCalibrationElbowAngle(result);
    final bodyDeviation = _pushUpCalibrationBodyLineDeviation(result);
    _landmarks = smoothed;
    _calibrationCurrentAngle = angle;
    if (angle == null || bodyDeviation == null) {
      notifyListeners();
      return;
    }

    switch (_pushUpCalibrationStage) {
      case _PushUpCalibrationStage.observeReps:
        _handlePushUpCalibrationFrame(
          angle: angle,
          bodyDeviation: bodyDeviation,
        );
      case _PushUpCalibrationStage.confirm:
        // Passive — waiting for the post-capture summary timer to fire
        // (set in `_completePushUpCalibration`). Per-frame angle stream is
        // ignored so a rebound rep can't accidentally re-arm the detector.
        break;
    }

    notifyListeners();
  }

  /// Per-frame work for the `observeReps` stage. Feeds the rep detector,
  /// applies body-line + MAD filtering on emit, advances to `confirm` once
  /// [kPushUpCalibrationTargetReps] valid reps are buffered.
  void _handlePushUpCalibrationFrame({
    required double angle,
    required double bodyDeviation,
  }) {
    final completed = _pushUpCalibrationRepDetector.onAngle(angle);
    if (completed == null) {
      // Update the standing instruction based on how many reps we've kept.
      final kept = _pushUpCalibrationTopSamples.length;
      if (kept == 0) {
        _pushUpCalibrationInstruction =
            'Do 3 controlled push-ups at your normal tempo.';
      } else {
        final remaining = kPushUpCalibrationTargetReps - kept;
        _pushUpCalibrationInstruction =
            'Captured $kept/$kPushUpCalibrationTargetReps — '
            '$remaining to go.';
      }
      return;
    }

    final (top, bottom) = completed;

    // Reject reps with bad posture at the moment of rep completion. A more
    // rigorous check would track the worst body-line throughout the rep
    // window; deferred for cost.
    if (bodyDeviation > kPushUpCalibrationBodyLineMaxDeviation) {
      TelemetryLog.instance.log(
        'pushup_calibration.rep_rejected',
        'reason=body_line top=${top.toStringAsFixed(1)} '
            'bottom=${bottom.toStringAsFixed(1)} '
            'body_dev=${bodyDeviation.toStringAsFixed(1)}',
      );
      _pushUpCalibrationInstruction =
          'Keep your body in one line — that rep was discarded. Try again.';
      return;
    }

    // Reject reps with extremes outside the calibration acceptance bands —
    // mirrors the pre-2026-05-15 hold-protocol gates so the saved profile
    // can't drift outside the validated ROM envelope.
    final outOfBand =
        top < kPushUpCalibrationTopMinAngle ||
        top > kPushUpCalibrationTopMaxAngle ||
        bottom < kPushUpCalibrationBottomMinAngle ||
        bottom > kPushUpCalibrationBottomMaxAngle;
    if (outOfBand) {
      TelemetryLog.instance.log(
        'pushup_calibration.rep_rejected',
        'reason=out_of_band top=${top.toStringAsFixed(1)} '
            'bottom=${bottom.toStringAsFixed(1)}',
      );
      _pushUpCalibrationInstruction =
          'That rep landed outside the calibration range — try a fuller '
          'rep with elbows nearly straight at the top.';
      return;
    }

    // MAD outlier rejection — only kicks in once we have ≥ 2 samples on
    // each axis. mad_outlier returns false (i.e. accept) for empty buffers.
    final topOutlier = mad.isMadOutlier(_pushUpCalibrationTopSamples, top);
    final bottomOutlier = mad.isMadOutlier(
      _pushUpCalibrationBottomSamples,
      bottom,
    );
    if (topOutlier || bottomOutlier) {
      TelemetryLog.instance.log(
        'pushup_calibration.rep_rejected',
        'reason=mad_outlier top=${top.toStringAsFixed(1)} '
            'bottom=${bottom.toStringAsFixed(1)} '
            'top_outlier=$topOutlier bottom_outlier=$bottomOutlier',
      );
      _pushUpCalibrationInstruction =
          'That rep looked different from the others — try one more with '
          'matching depth.';
      return;
    }

    _pushUpCalibrationTopSamples.add(top);
    _pushUpCalibrationBottomSamples.add(bottom);
    _calibrationReps = _pushUpCalibrationTopSamples.length;
    TelemetryLog.instance.log(
      'pushup_calibration.rep_captured',
      'rep=${_pushUpCalibrationTopSamples.length} '
          'top=${top.toStringAsFixed(1)} '
          'bottom=${bottom.toStringAsFixed(1)}',
    );

    if (_pushUpCalibrationTopSamples.length < kPushUpCalibrationTargetReps) {
      final remaining =
          kPushUpCalibrationTargetReps - _pushUpCalibrationTopSamples.length;
      _pushUpCalibrationInstruction =
          'Captured '
          '${_pushUpCalibrationTopSamples.length}/'
          '$kPushUpCalibrationTargetReps — $remaining to go.';
      _tts.speak('Good. Keep going.');
      return;
    }

    // All reps captured — compute anchors and advance to confirm.
    final topAnchor = _pushUpCalibrationTopSamples.reduce(math.max);
    final bottomAnchor = _pushUpCalibrationBottomSamples.reduce(math.min);
    _pushUpCalibrationTopAngle = topAnchor;
    _pushUpCalibrationStage = _PushUpCalibrationStage.confirm;
    _pushUpCalibrationInstruction =
        'All reps captured. Saving your range of motion.';
    _tts.speak('Range captured.');
    _completePushUpCalibration(bottomAngle: bottomAnchor);
  }

  void _completePushUpCalibration({required double bottomAngle}) {
    final top = _pushUpCalibrationTopAngle;
    if (top == null) {
      _failCalibration('Top position was not captured. Try again.');
      return;
    }

    PushUpRomProfile profile;
    try {
      profile = PushUpRomProfile.calibrated(
        topAngle: top,
        bottomAngle: bottomAngle,
        sampleCount: _pushUpCalibrationBottomSamples.length,
      );
    } catch (e) {
      _failCalibration(e.toString());
      return;
    }

    _calibrationTimeoutTimer?.cancel();
    _pushUpProfile = profile;
    _repCounter.updatePushUpThresholds(profile.thresholds);
    unawaited(
      _profileRepository.savePushUp(profile).catchError((Object e) {
        TelemetryLog.instance.log('pushup_profile.save_failed', e.toString());
      }),
    );
    _calibrationReps = 3;
    TelemetryLog.instance.log(
      'pushup_calibration.complete',
      'top=${top.toStringAsFixed(1)} bottom=${bottomAngle.toStringAsFixed(1)}',
    );
    _calibrationSummary = CalibrationSummary(
      viewLabel: 'Push-up ROM',
      sidesLabel:
          'Top ${top.toStringAsFixed(0)}° · Bottom ${bottomAngle.toStringAsFixed(0)}°',
    );
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      _calibrationSummary = null;
      if (forceCalibration) {
        _disposeCalibrationResources();
        _shouldExitAfterCalibration = true;
        notifyListeners();
        return;
      }
      _exitCalibration(toPhase: WorkoutPhase.setupCheck);
    });
  }

  double? _pushUpCalibrationElbowAngle(PoseResult result) {
    final left = _pushUpSideElbowAngle(result, isLeft: true);
    final right = _pushUpSideElbowAngle(result, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right!.$1;
    if (right == null) return left.$1;
    return left.$2 >= right.$2 ? left.$1 : right.$1;
  }

  (double, double)? _pushUpSideElbowAngle(
    PoseResult result, {
    required bool isLeft,
  }) {
    final shoulder = result.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final elbow = result.landmark(
      isLeft ? LM.leftElbow : LM.rightElbow,
      minConfidence: kMinLandmarkConfidence,
    );
    final wrist = result.landmark(
      isLeft ? LM.leftWrist : LM.rightWrist,
      minConfidence: kMinLandmarkConfidence,
    );
    final elbowAngle = angleDeg(shoulder, elbow, wrist);
    if (shoulder == null ||
        elbow == null ||
        wrist == null ||
        elbowAngle == null) {
      return null;
    }
    return (
      elbowAngle,
      shoulder.confidence + elbow.confidence + wrist.confidence,
    );
  }

  double? _pushUpCalibrationBodyLineDeviation(PoseResult result) {
    final left = _pushUpSideBodyLineDeviation(result, isLeft: true);
    final right = _pushUpSideBodyLineDeviation(result, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right!.$1;
    if (right == null) return left.$1;
    return left.$2 >= right.$2 ? left.$1 : right.$1;
  }

  (double, double)? _pushUpSideBodyLineDeviation(
    PoseResult result, {
    required bool isLeft,
  }) {
    final shoulder = result.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = result.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = result.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    final hipAngle = angleDeg(shoulder, hip, ankle);
    if (shoulder == null || hip == null || ankle == null || hipAngle == null) {
      return null;
    }
    return (
      (180.0 - hipAngle).abs(),
      shoulder.confidence + hip.confidence + ankle.confidence,
    );
  }

  // ── Frame pipeline ────────────────────────────────────
  void _onFrame(CameraImage image) {
    if (_isProcessing) return;

    final intervalMs = switch (_phase) {
      WorkoutPhase.active => kActiveFrameIntervalMs,
      WorkoutPhase.calibration => kCalibrationFrameIntervalMs,
      _ => kIdleFrameIntervalMs,
    };
    final nowMs = _frameClock.elapsedMilliseconds;
    if (nowMs - _lastProcessedMs < intervalMs) return;

    _lastProcessedMs = nowMs;
    _isProcessing = true;

    _processFrame(image).whenComplete(() {
      _isProcessing = false;
    });
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      // Required-landmark gate: tell the pose service which landmarks the
      // active exercise actually depends on, so a frame missing any of
      // them is rejected at the boundary instead of feeding the engine a
      // partial body.
      //
      // Side-view curls (any locked view AND pre-detection) ALWAYS run
      // dual-group: accept the frame if EITHER {11,13,15} OR {12,14,16}
      // is fully present. Reason: ML Kit's anatomical labels don't
      // reliably match the user's declared orientation in side recordings
      // — we've observed sessions where the user turned their right side
      // to the camera but ML Kit labeled the visible arm as
      // `leftShoulder/leftElbow/leftWrist`. Demanding a specific arm
      // based on declared side fails such sessions entirely. Instead the
      // gate is arm-agnostic for side; the strategy's
      // `computePrimaryAngle` already handles whichever arm shows up.
      //
      // Front view still demands both arms (asymmetry detection needs
      // both, and 2D projection makes both reliably trackable).
      final isSideCurl =
          exercise == ExerciseType.bicepsCurlSide ||
          // ignore: deprecated_member_use_from_same_package
          exercise == ExerciseType.bicepsCurl &&
              _detectedCurlView != CurlCameraView.front;
      final isPushUp = exercise == ExerciseType.pushUp;
      final isPlank = exercise == ExerciseType.plank;
      final List<int> gatePrimary;
      final List<int>? gateAlt;
      if (isSideCurl) {
        gatePrimary = const [11, 13, 15]; // left arm trio
        gateAlt = const [12, 14, 16]; // right arm trio
      } else if (isPushUp) {
        gatePrimary = _pushUpLeftSideLandmarks;
        gateAlt = _pushUpRightSideLandmarks;
      } else if (isPlank) {
        gatePrimary = _plankLeftCoreLandmarks;
        gateAlt = _plankRightCoreLandmarks;
      } else {
        gatePrimary = ExerciseRequirements.forExerciseAndView(
          exercise,
          _detectedCurlView,
        ).landmarkIndices;
        gateAlt = null;
      }
      // Side-view curls run with a relaxed confidence floor (ML Kit can't
      // cross-anchor against the off-camera arm so all confidences drop)
      // and treat wrists (15, 16) as best-effort — the wrist is the noisiest
      // landmark at peak flexion and the FSM can tolerate occasional
      // wrist-missing frames (the angle calc returns null and the FSM
      // simply skips that frame).
      final double? gateFloor = isSideCurl
          ? kPoseGateMinConfidenceSideRelaxed
          : isPlank
          ? kPlankMinLandmarkConfidence
          : null;
      final Set<int>? gateBestEffort = isSideCurl
          ? const {15, 16}
          : isPlank
          ? const {
              LM.leftWrist,
              LM.rightWrist,
              LM.leftKnee,
              LM.rightKnee,
              LM.leftAnkle,
              LM.rightAnkle,
            }
          : null;

      // Push-up landscape uses the OS-coherent rotation model: the push-up
      // WorkoutScreen unlocks landscape via SystemChrome, so iOS/Android
      // rotate the UI + camera + capture buffer together and the buffer's
      // `size` and ML Kit's declared `rotation` stay in sync. The legacy
      // raw `sensorRotation` is therefore correct in BOTH portrait and
      // OS-rotated landscape — no engine-side rotation reconciliation. (An
      // earlier engine-only approach computing rotation from the
      // accelerometer was reverted 2026-05-16 after an on-device probe
      // proved iOS desyncs buffer-vs-declared rotation; see WISDOM.)
      final result = await _pose.processCameraImage(
        image,
        _camera.sensorRotation,
        requiredLandmarks: gatePrimary,
        requiredLandmarksAlt: gateAlt,
        confidenceFloor: gateFloor,
        bestEffortLandmarks: gateBestEffort,
      );

      // Camera-framing hint: track sustained nearedge during pre-active
      // phases. We surface the hint ONLY before the workout actually
      // starts — once active, hints would be more noise than signal.
      // Cleared on first clean frame.
      final preActive =
          _phase == WorkoutPhase.setupCheck || _phase == WorkoutPhase.countdown;
      if (preActive && _pose.lastFrameNearEdge) {
        _nearEdgeStreak++;
        if (_nearEdgeStreak >= _kFramingHintFrames && _framingHint == null) {
          _framingHint = 'Step back so your full body is in frame';
          notifyListeners();
        }
      } else {
        if (_nearEdgeStreak > 0 || _framingHint != null) {
          _nearEdgeStreak = 0;
          _framingHint = null;
          notifyListeners();
        }
      }

      if (result.isEmpty) return;

      // On iOS, ML Kit returns coordinates that already match the mirrored
      // CameraPreview (selfie mode), so no extra flip is needed.
      // On Android front camera, ML Kit returns raw sensor coords — flip X.
      final needsMirror = PlatformConfig.instance.frontCameraNeedsMirror(
        isFrontCamera: _camera.isFrontCamera,
      );
      final displayLandmarks = result.landmarks
          .map(
            (lm) => PoseLandmark(
              type: lm.type,
              x: needsMirror ? 1.0 - lm.x : lm.x,
              y: lm.y,
              confidence: lm.confidence,
            ),
          )
          .toList();
      final smoothed = _displaySmoother.smooth(displayLandmarks);

      switch (_phase) {
        case WorkoutPhase.calibration:
          _updateCalibration(result, smoothed);
        case WorkoutPhase.setupCheck:
          _updateSetupCheck(result, smoothed);
        case WorkoutPhase.countdown:
          _updateCountdownFrame(result, smoothed);
        case WorkoutPhase.active:
          _updateActive(result, smoothed);
        case WorkoutPhase.completed:
          break;
      }
    } catch (e, st) {
      // Drop the bad frame — the camera stream must not crash. But do not
      // swallow silently (AGENT_DIRECTIVES §2.5): a recurring engine
      // exception here would otherwise burn CPU 15×/s AND stay invisible.
      // Throttled to 1/sec so a degraded session can't flood the ring
      // buffer (mirrors MlKitPoseService._maybeWarnQuality).
      final now = DateTime.now();
      final last = _lastFrameDropWarnAt;
      if (last == null || now.difference(last).inMilliseconds >= 1000) {
        _lastFrameDropWarnAt = now;
        TelemetryLog.instance.log(
          'workout.frame_dropped',
          '${e.runtimeType}: $e',
          data: {'stack': st.toString().split('\n').take(3).join(' | ')},
        );
      }
      // Intentionally no rethrow — the frame is dropped by design.
    }
  }

  // ── SETUP_CHECK ────────────────────────────────────────
  bool _landmarkGroupVisible(
    PoseResult result,
    List<int> indices, {
    required double minConfidence,
  }) => indices.every(
    (idx) => result.landmark(idx, minConfidence: minConfidence) != null,
  );

  bool _pushUpSideVisible(PoseResult result, {required double minConfidence}) =>
      _landmarkGroupVisible(
        result,
        _pushUpLeftSideLandmarks,
        minConfidence: minConfidence,
      ) ||
      _landmarkGroupVisible(
        result,
        _pushUpRightSideLandmarks,
        minConfidence: minConfidence,
      );

  bool _plankSideVisible(PoseResult result, {required double minConfidence}) =>
      _plankSideCoreAndLowerVisible(
        result,
        _plankLeftCoreLandmarks,
        _plankLeftLowerLandmarks,
        minConfidence: minConfidence,
      ) ||
      _plankSideCoreAndLowerVisible(
        result,
        _plankRightCoreLandmarks,
        _plankRightLowerLandmarks,
        minConfidence: minConfidence,
      );

  bool _plankSideCoreAndLowerVisible(
    PoseResult result,
    List<int> core,
    List<int> lowerBody, {
    required double minConfidence,
  }) =>
      _landmarkGroupVisible(result, core, minConfidence: minConfidence) &&
      lowerBody.any(
        (idx) => result.landmark(idx, minConfidence: minConfidence) != null,
      );

  bool _plankAnySideLandmarkVisible(
    PoseResult result, {
    required double minConfidence,
  }) {
    for (final idx in {
      ..._plankLeftCoreLandmarks,
      ..._plankRightCoreLandmarks,
      ..._plankLeftLowerLandmarks,
      ..._plankRightLowerLandmarks,
      LM.leftWrist,
      LM.rightWrist,
    }) {
      if (result.landmark(idx, minConfidence: minConfidence) != null) {
        return true;
      }
    }
    return false;
  }

  bool _pushUpAnySideLandmarkVisible(
    PoseResult result, {
    required double minConfidence,
  }) {
    for (final idx in {
      ..._pushUpLeftSideLandmarks,
      ..._pushUpRightSideLandmarks,
    }) {
      if (result.landmark(idx, minConfidence: minConfidence) != null) {
        return true;
      }
    }
    return false;
  }

  Map<int, Color> _plankSetupLandmarkColors(
    PoseResult result, {
    required double minConfidence,
  }) {
    final leftVisible = _plankSideCoreAndLowerVisible(
      result,
      _plankLeftCoreLandmarks,
      _plankLeftLowerLandmarks,
      minConfidence: minConfidence,
    );
    final rightVisible = _plankSideCoreAndLowerVisible(
      result,
      _plankRightCoreLandmarks,
      _plankRightLowerLandmarks,
      minConfidence: minConfidence,
    );
    if (leftVisible || rightVisible) {
      final core =
          leftVisible ? _plankLeftCoreLandmarks : _plankRightCoreLandmarks;
      final lower =
          leftVisible ? _plankLeftLowerLandmarks : _plankRightLowerLandmarks;
      return {
        for (final idx in core) idx: const Color(0xFF00E676),
        for (final idx in lower)
          if (result.landmark(idx, minConfidence: minConfidence) != null)
            idx: const Color(0xFF00E676),
      };
    }

    final colors = <int, Color>{};
    for (final idx in {
      ..._plankLeftCoreLandmarks,
      ..._plankRightCoreLandmarks,
      ..._plankLeftLowerLandmarks,
      ..._plankRightLowerLandmarks,
    }) {
      colors[idx] = result.landmark(idx, minConfidence: minConfidence) != null
          ? const Color(0xFF00E676)
          : Colors.redAccent;
    }
    return colors;
  }

  Map<int, Color> _pushUpSetupLandmarkColors(
    PoseResult result, {
    required double minConfidence,
  }) {
    final leftVisible = _landmarkGroupVisible(
      result,
      _pushUpLeftSideLandmarks,
      minConfidence: minConfidence,
    );
    final rightVisible = _landmarkGroupVisible(
      result,
      _pushUpRightSideLandmarks,
      minConfidence: minConfidence,
    );
    if (leftVisible || rightVisible) {
      return {
        for (final idx
            in leftVisible
                ? _pushUpLeftSideLandmarks
                : _pushUpRightSideLandmarks)
          idx: const Color(0xFF00E676),
      };
    }

    final colors = <int, Color>{};
    for (final idx in {
      ..._pushUpLeftSideLandmarks,
      ..._pushUpRightSideLandmarks,
    }) {
      colors[idx] = result.landmark(idx, minConfidence: minConfidence) != null
          ? const Color(0xFF00E676)
          : Colors.redAccent;
    }
    return colors;
  }

  void _updateSetupCheck(PoseResult result, List<PoseLandmark> smoothed) {
    if (exercise.isCurl) {
      final view = _repCounter.updateSetupView(result);
      if (view != _detectedCurlView) _detectedCurlView = view;
    }

    final requirements = ExerciseRequirements.forExercise(exercise);
    var colors = <int, Color>{};
    var allVisible = true;

    // Curl exercises apply a stricter confidence floor during setup to reject
    // bystanders whose landmarks are partially visible at the frame edges.
    final double setupConfidence = exercise.isCurl
        ? kSetupCurlMinConfidence
        : exercise == ExerciseType.plank
        ? kPlankMinLandmarkConfidence
        : kMinLandmarkConfidence;

    if (exercise == ExerciseType.pushUp) {
      allVisible = _pushUpSideVisible(result, minConfidence: setupConfidence);
      colors = _pushUpSetupLandmarkColors(
        result,
        minConfidence: setupConfidence,
      );
    } else if (exercise == ExerciseType.plank) {
      allVisible = _plankSideVisible(result, minConfidence: setupConfidence);
      colors = _plankSetupLandmarkColors(
        result,
        minConfidence: setupConfidence,
      );
    } else {
      for (final idx in requirements.landmarkIndices) {
        final lm = result.landmark(idx, minConfidence: setupConfidence);
        if (lm != null) {
          colors[idx] = const Color(0xFF00E676);
        } else {
          colors[idx] = Colors.redAccent;
          allVisible = false;
        }
      }
    }

    // Curl posture check: at least one arm must be in a resting-arm angle
    // range (130°–185°). Catches bystanders whose arms happen to pass the
    // confidence gate but are mid-gesture or mid-walk.
    if (allVisible && exercise.isCurl) {
      final leftAngle = angleDeg(
        result.landmark(LM.leftShoulder, minConfidence: setupConfidence),
        result.landmark(LM.leftElbow, minConfidence: setupConfidence),
        result.landmark(LM.leftWrist, minConfidence: setupConfidence),
      );
      final rightAngle = angleDeg(
        result.landmark(LM.rightShoulder, minConfidence: setupConfidence),
        result.landmark(LM.rightElbow, minConfidence: setupConfidence),
        result.landmark(LM.rightWrist, minConfidence: setupConfidence),
      );
      final bool leftResting =
          leftAngle != null &&
          leftAngle >= kSetupRestingArmMinDeg &&
          leftAngle <= kSetupRestingArmMaxDeg;
      final bool rightResting =
          rightAngle != null &&
          rightAngle >= kSetupRestingArmMinDeg &&
          rightAngle <= kSetupRestingArmMaxDeg;
      if (!leftResting && !rightResting) allVisible = false;
    }

    // Industry-standard "Frame Check": after landmarks pass confidence and
    // curl posture, verify the camera is at a usable height/distance. A
    // too-high or too-low lens keystones the torso and silently breaks
    // angle-based rep counting — surfacing the failure here prevents the
    // user from starting a set the analyzer cannot read. Curl-only for
    // now; squat/push-up have their own view-specific framing needs.
    if (allVisible && exercise.isCurl) {
      final framing = evaluateSetupFraming(
        result,
        minConfidence: setupConfidence,
      );
      _setupFramingHint = framing.hint;
      if (!framing.ok) allVisible = false;
    } else if (!exercise.isCurl) {
      _setupFramingHint = null;
    }

    if (allVisible) {
      _setupFramingHint = null;
      _setupOkFrames++;
      if (_setupOkFrames >= kSetupCheckFrames) {
        _phase = WorkoutPhase.countdown;
        _landmarks = smoothed;
        _landmarkColors = {};
        _startCountdown();
        notifyListeners();
        return;
      }
    } else {
      _setupOkFrames = 0;
    }

    _landmarks = smoothed;
    _landmarkColors = colors;
    notifyListeners();
  }

  // ── COUNTDOWN ──────────────────────────────────────────
  void _startCountdown() {
    _countdownValue = kCountdownSeconds;
    _tts.speak('$_countdownValue');
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _countdownValue--;
      if (_countdownValue > 0) {
        _tts.speak('$_countdownValue');
        notifyListeners();
      } else {
        timer.cancel();
        _tts.speak('Go! Starting ${exercise.label}');
        _phase = WorkoutPhase.active;
        _activeStart = DateTime.now();
        _landmarkColors = {};
        notifyListeners();
      }
    });
  }

  void _updateCountdownFrame(PoseResult result, List<PoseLandmark> smoothed) {
    if (exercise.isCurl) {
      final view = _repCounter.updateSetupView(result);
      if (view != _detectedCurlView) _detectedCurlView = view;
    }

    final requirements = ExerciseRequirements.forExercise(exercise);
    final visibilityConfidence = exercise == ExerciseType.plank
        ? kPlankMinLandmarkConfidence
        : kMinLandmarkConfidence;
    final allVisible =
        exercise == ExerciseType.pushUp
        ? _pushUpSideVisible(result, minConfidence: visibilityConfidence)
        : exercise == ExerciseType.plank
        ? _plankSideVisible(result, minConfidence: visibilityConfidence)
        : requirements.landmarkIndices.every(
            (idx) =>
                result.landmark(idx, minConfidence: visibilityConfidence) !=
                null,
          );

    if (!allVisible) {
      _countdownTimer?.cancel();
      _tts.stop();
      _phase = WorkoutPhase.setupCheck;
      _setupOkFrames = 0;
      _setupFramingHint = null;
      _countdownValue = kCountdownSeconds;
      _landmarks = smoothed;
      notifyListeners();
    } else {
      _landmarks = smoothed;
      notifyListeners();
    }
  }

  // ── ACTIVE ─────────────────────────────────────────────
  void _updateActive(PoseResult result, List<PoseLandmark> smoothed) {
    if (exercise.isCurl) {
      final view = _repCounter.updateSetupView(result);
      if (view != _detectedCurlView) {
        _detectedCurlView = view;
        _maybeShowUncalibratedNotice(view);
      }
    }

    final requirements = ExerciseRequirements.forExercise(exercise);
    final visibilityConfidence = exercise == ExerciseType.plank
        ? kPlankMinLandmarkConfidence
        : kMinLandmarkConfidence;
    final total = requirements.landmarkIndices.length;
    final visible = requirements.landmarkIndices
        .where(
          (idx) =>
              result.landmark(idx, minConfidence: visibilityConfidence) !=
              null,
        )
        .length;
    final hasRequiredPose =
        exercise == ExerciseType.pushUp
        ? _pushUpSideVisible(result, minConfidence: visibilityConfidence)
        : exercise == ExerciseType.plank
        ? _plankSideVisible(result, minConfidence: visibilityConfidence)
        : visible == total;
    final hasPartialPose =
        exercise == ExerciseType.pushUp
        ? _pushUpAnySideLandmarkVisible(
            result,
            minConfidence: visibilityConfidence,
          )
        : exercise == ExerciseType.plank
        ? _plankAnySideLandmarkVisible(
            result,
            minConfidence: visibilityConfidence,
          )
        : visible > 0;

    if (hasRequiredPose) {
      _absenceStart = null;
      _occlusionStart = null;

      if (_isOccluded) {
        _occlusionResumeFrames++;
        if (_occlusionResumeFrames >= kOcclusionResumeFrames) {
          _isOccluded = false;
          _occlusionResumeFrames = 0;
        }
      }

      final snapshot = _repCounter.update(result);
      // Curl-debug-session frame metrics. Throttled to ~kDebugFrameMetricsHz
      // independent of camera FPS so the ring buffer doesn't flood. Emits
      // only during the active phase (no point logging frames during
      // setupCheck or countdown — the user isn't curling yet). Gated by
      // both the compile-time flag and the runtime preference; both must
      // be true for the entire branch to fire.
      if (kCurlDebugSessionEnabled &&
          _isCurlDebugSession &&
          _phase == WorkoutPhase.active) {
        final intervalMs = (1000.0 / kDebugFrameMetricsHz).round();
        final last = _lastDebugFrameMetricsAt;
        final stamp = DateTime.now();
        if (last == null ||
            stamp.difference(last).inMilliseconds >= intervalMs) {
          _lastDebugFrameMetricsAt = stamp;
          _emitDebugFrameMetrics(result, snapshot);
        }
      }
      if (kSquatDebugSessionEnabled &&
          _isSquatDebugSession &&
          _phase == WorkoutPhase.active) {
        final intervalMs = (1000.0 / kSquatDebugFrameMetricsHz).round();
        final last = _lastSquatDebugFrameMetricsAt;
        final stamp = DateTime.now();
        if (last == null ||
            stamp.difference(last).inMilliseconds >= intervalMs) {
          _lastSquatDebugFrameMetricsAt = stamp;
          _emitSquatDebugFrameMetrics(result, snapshot);
        }
      }
      if (snapshot.formErrors.isNotEmpty) _onFormErrors(snapshot.formErrors);
      // Progress audio: rep exercises speak counts; plank uses milestone
      // speech plus a light click between milestones. Suppressed during debug
      // session — the user explicitly opted into silent observation. Squat
      // mirrors the curl contract.
      final previousReps = _snapshot.reps;
      final advanced = snapshot.reps > previousReps;
      final isDebugSilent =
          (kCurlDebugSessionEnabled && _isCurlDebugSession) ||
          (kSquatDebugSessionEnabled && _isSquatDebugSession) ||
          (kPushUpDebugSessionEnabled && _isPushUpDebugSession);
      _landmarks = smoothed;
      _snapshot = snapshot;
      notifyListeners();
      if (advanced && snapshot.reps >= targetCount) {
        if (!isDebugSilent) unawaited(_tts.speak('Well done'));
        _triggerCompleted();
        return;
      }
      if (!isDebugSilent && advanced) {
        _playProgressCue(snapshot.reps);
      }
    } else if (hasPartialPose) {
      // Partial occlusion — user still present.
      _absenceStart = null;
      _occlusionResumeFrames = 0;
      _occlusionStart ??= DateTime.now();

      final occludedMs = DateTime.now()
          .difference(_occlusionStart!)
          .inMilliseconds;
      if (occludedMs >= kOcclusionPromptSec * 1000 && !_isOccluded) {
        _isOccluded = true;
        if (_canSpeakOcclusionPrompt()) {
          _tts.speak('Move into frame — keep all joints visible');
          _lastOcclusionTts = DateTime.now();
        }
      }
      _landmarks = smoothed;
      notifyListeners();
    } else {
      // Full absence.
      _occlusionStart = null;
      _occlusionResumeFrames = 0;
      if (_isOccluded) {
        _isOccluded = false;
        notifyListeners();
      }

      _absenceStart ??= DateTime.now();
      final absentMs = DateTime.now().difference(_absenceStart!).inMilliseconds;
      if (absentMs >= kAbsenceTimeoutSec * 1000) {
        _triggerCompleted();
      }
    }
  }

  void _playProgressCue(int count) {
    if (exercise == ExerciseType.plank) {
      if (_shouldSpeakPlankTime(count)) {
        unawaited(_tts.speak('$count seconds'));
      } else {
        unawaited(SystemSound.play(SystemSoundType.click));
      }
      return;
    }
    unawaited(_tts.speak('$count'));
  }

  bool _shouldSpeakPlankTime(int seconds) {
    if (seconds <= 0) return false;
    if (seconds <= 120) return seconds % 10 == 0;
    return seconds % 30 == 0;
  }

  /// Whether the given form error should be suppressed from the TTS path.
  /// Visual highlight still fires, but no spoken cue and no cooldown slot
  /// is consumed. The current suppression set is `{forwardKneeShift}` —
  /// informational metric, plan flow-decision: no TTS, no quality penalty.
  ///
  /// Exposed for unit testing in `workout_view_model_test.dart` so the
  /// suppression contract is locked against future enum-switch additions.
  @visibleForTesting
  static bool isTtsSuppressed(FormError err) =>
      err == FormError.forwardKneeShift;

  /// Test seam exposing the spoken cue for a given form error. Lets
  /// the test suite pin the user-visible TTS phrasing — without this,
  /// a future refactor could silently swap the cue for a regression.
  /// Mirrors the `isTtsSuppressed` pattern on the same surface.
  @visibleForTesting
  static String errorMessageForTest(FormError err) => _errorMessage(err);

  /// Test seam: drives the same form-feedback coordinator path the
  /// pose-loop drives, without needing to instantiate the engine or
  /// pump pose frames. Used by the `TtsVerbosity` cap tests to assert
  /// the gate behavior in isolation.
  @visibleForTesting
  void triggerFormErrorsForTest(List<FormError> errors) =>
      _onFormErrors(errors);

  /// Test seam: overrides the session's verbosity snapshot. The
  /// production path reads this from `PreferencesRepository.getTtsVerbosity`
  /// during [init]; tests can short-circuit that.
  @visibleForTesting
  void setTtsVerbosityForTest(TtsVerbosity value) => _ttsVerbosity = value;

  // ── Form feedback coordinator ─────────────────────────
  void _onFormErrors(List<FormError> errors) {
    // Debug session (curl OR squat): silent observation. Skip cooldown
    // bookkeeping, TTS, and visual highlights entirely — the analyzer's
    // per-rep telemetry still fires (we want the data), but nothing
    // reaches the user. `_formErrorCounts` is intentionally NOT
    // incremented either, so the post-session summary doesn't show
    // inflated counts that never had a chance to be seen and corrected
    // mid-set. Squat mirrors the curl contract.
    if ((kCurlDebugSessionEnabled && _isCurlDebugSession) ||
        (kSquatDebugSessionEnabled && _isSquatDebugSession) ||
        (kPushUpDebugSessionEnabled && _isPushUpDebugSession)) {
      return;
    }
    final now = DateTime.now();
    for (final err in errors) {
      // forwardKneeShift is informational — visual highlight only, no TTS
      // and no quality penalty (handled in the analyzer). Skip the cooldown
      // bookkeeping too so it doesn't block other cues.
      if (isTtsSuppressed(err)) {
        _triggerHighlight(err);
        continue;
      }
      final cooldownKey = _cooldownKeyFor(err);
      final last = _lastFeedbackTime[cooldownKey];
      if (last != null &&
          now.difference(last).inSeconds < kFeedbackCooldownSec) {
        continue;
      }
      _lastFeedbackTime[cooldownKey] = now;
      _formErrorCounts[err] = (_formErrorCounts[err] ?? 0) + 1;
      // Per-error voice-cue cap. `high` is unlimited (every fire that passes
      // the time-cooldown is spoken); `medium` and `low` clamp the audio
      // after [kTtsVerbosityMediumCap] / [kTtsVerbosityLowCap] fires of the
      // *same* error this session. The visual highlight below still runs
      // unconditionally, and the bumped `_formErrorCounts[err]` is what the
      // session-end summary reads — silencing the voice does NOT silence
      // detection.
      //
      // Persistence re-arm: once the cap mutes an error, a *persistent*
      // fault (one that keeps clearing the time-cooldown) is re-alerted
      // exactly once every re-arm window, then re-muted. The cooldown
      // collapses multi-frame spam to ≈ 1 fire/rep, so the window is
      // effectively "this many more faulty reps." A user who fixes the
      // fault never hears it again; a stuck user gets a periodic nudge
      // instead of permanent silence. `high` has no cap, so the re-arm
      // block is inert there (zero behavior change).
      final cap = switch (_ttsVerbosity) {
        TtsVerbosity.high => null,
        TtsVerbosity.medium => kTtsVerbosityMediumCap,
        TtsVerbosity.low => kTtsVerbosityLowCap,
      };
      final reArmWindow = switch (_ttsVerbosity) {
        TtsVerbosity.high => null,
        TtsVerbosity.medium => kTtsPersistenceReArmRepsMedium,
        TtsVerbosity.low => kTtsPersistenceReArmRepsLow,
      };

      final underCap = cap == null || _formErrorCounts[err]! <= cap;
      var speak = underCap;

      if (!underCap && reArmWindow != null) {
        // Cap has muted this error. Count muted cooldown-clears; on the
        // reArmWindow-th, allow exactly one re-alert, then re-mute for a
        // fresh full window (reset to 0). Mirrors the proven
        // `_tempoReArmRepsRemaining = kTempoConsistencyReArmReps` shape.
        final streak = (_mutedFireStreak[err] ?? 0) + 1;
        if (streak >= reArmWindow) {
          speak = true;
          _mutedFireStreak[err] = 0;
        } else {
          _mutedFireStreak[err] = streak;
        }
      }

      if (speak) {
        _tts.speak(_errorMessage(err));
      }
      _triggerHighlight(err);
      break; // one cue per update — list order defines priority
    }
  }

  /// Squat-only rep commit callback. Captures per-rep metrics for the
  /// summary screen AND feeds the in-session auto-calibrator + persistent
  /// profile bucket with the rep's ROM extremes.
  void _handleSquatRepCommit({
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
    required double? signedLeanAtPeak,
    required int backwardLeanFrameCount,
    required Duration? concentricDuration,
  }) {
    _squatRepMetrics.add(
      SquatRepMetrics(
        repIndex: repIndex,
        quality: quality,
        leanDeg: leanDeg,
        kneeShiftRatio: kneeShiftRatio,
        heelLiftRatio: heelLiftRatio,
      ),
    );

    // Buffer the ascent (concentric/lift) duration for `concentric_ms`
    // persistence + the cross-session fatigue baseline. Index-aligned with
    // reps, exactly like the curl path (`_handleCurlRepCommit`). Null on a
    // rep with no measured ascent (vetoed half-squats still reach here, but
    // their duration is non-null — the rolling-window contamination guard
    // lives in the engine, not here).
    _repConcentricDurations.add(concentricDuration);

    _recordSquatExtremes(minKneeAngle, maxKneeAngle);

    // Always log — not gated on debug session. Production data is valuable
    // for threshold derivation. The Python script filters by variant.
    _squatDebugRepIndex++;
    TelemetryLog.instance.log(
      'squat.rep',
      'rep=$_squatDebugRepIndex '
          'variant=${_squatVariant.name} '
          'long_femur=$_squatLongFemurLifter '
          'lean_deg=${leanDeg?.toStringAsFixed(2) ?? "null"} '
          'knee_shift=${kneeShiftRatio?.toStringAsFixed(4) ?? "null"} '
          'heel_lift=${heelLiftRatio?.toStringAsFixed(4) ?? "null"} '
          'quality=${quality?.toStringAsFixed(3) ?? "null"} '
          'min_knee=${minKneeAngle?.toStringAsFixed(2) ?? "null"} '
          'max_knee=${maxKneeAngle?.toStringAsFixed(2) ?? "null"} '
          'lean_exceed_frac=${leanExceedFrac?.toStringAsFixed(4) ?? "null"} '
          'effective_bottom=${_repCounter.squatEffectiveBottomAngle?.toStringAsFixed(2) ?? "null"} '
          'signed_lean=${signedLeanAtPeak?.toStringAsFixed(2) ?? "null"} '
          'backward_lean_frames=$backwardLeanFrameCount',
    );

    // Hip-lead diagnostic line — separate from `squat.rep` so the Python
    // tuning workflow can filter by tag. Null ratio means the rep had
    // fewer than `kHipLeadMinAscendingFrames` raw ASCENDING frames OR <4
    // valid velocity pairs after the stationary-shoulder filter; either
    // way no grade was emitted (fail-open). `ascending_frame_count`
    // contextualizes the ratio — a ratio computed from 6 frames carries
    // less signal than one from 20.
    final hipLeadFrames = _repCounter.squatAscendingFrameCount ?? 0;
    TelemetryLog.instance.log(
      'squat.hip_lead',
      'rep=$_squatDebugRepIndex '
          'ratio=${hipLeadRatio?.toStringAsFixed(3) ?? "null"} '
          'ascending_frame_count=$hipLeadFrames '
          'threshold=$kHipLeadVelocityRatio',
    );

    // Knee-led-descent diagnostic line — separate from `squat.rep` so the
    // Python tuning workflow can filter by tag (mirrors `squat.hip_lead`).
    // Null ratio means the rep had fewer than `kSquatKneeLedMinFrames`
    // samples in the early-descent window OR a degenerate leg length;
    // either way no grade was emitted (fail-open). `window_frames`
    // contextualizes the ratio the same way `ascending_frame_count` does
    // for hip-lead.
    final kneeLedFrames = _repCounter.squatKneeLedSampleCount ?? 0;
    TelemetryLog.instance.log(
      'squat.knee_led',
      'rep=$_squatDebugRepIndex '
          'ratio=${kneeLedRatio?.toStringAsFixed(3) ?? "null"} '
          'window_frames=$kneeLedFrames '
          'threshold=$kSquatKneeLedMinRatio',
    );
  }

  /// Push-up rep commit callback. Emits the `pushup.rep` telemetry line
  /// consumed by the offline ROM-derivation script. Always-on (not gated
  /// on a debug-session toggle) — production data is valuable for
  /// threshold derivation, mirroring squat's emission policy.
  ///
  /// The rep counter passes the analyzer's snapshot extremes (`null` when
  /// not captured — rare edge cases). The format helper emits the literal
  /// string `"null"` so the Python parser regex stays anchored.
  void _handlePushUpRepCommit({
    required int repIndex,
    required double? minElbowAngle,
    required double? maxElbowAngle,
    required Duration? concentricDuration,
  }) {
    // Buffer the ascent (concentric/press) duration for `concentric_ms`
    // persistence + the cross-session fatigue baseline. Index-aligned with
    // reps, exactly like curl/squat. Null on a shallow rep with no measured
    // ascent — the engine already skipped its tempo signals for that rep.
    _repConcentricDurations.add(concentricDuration);
    _pushUpDebugRepIndex++;
    TelemetryLog.instance.log(
      'pushup.rep',
      formatPushUpRepLine(
        repIndex: _pushUpDebugRepIndex,
        minElbowAngle: minElbowAngle,
        maxElbowAngle: maxElbowAngle,
      ),
    );
    // Push-up reuses `CurlRepRecord` as a generic min/max-angle carrier so
    // the Form Auditor's push-up path (which only reads `minAngle` /
    // `maxAngle`) and the Session Complete page's unified summary both see
    // the rep. `side` / `view` / `source` are not meaningful for push-up;
    // sentinel values are picked that the audit path never inspects.
    // Without this append, `auditPushUp` returns "No reps recorded"
    // on every live push-up session.
    if (minElbowAngle != null && maxElbowAngle != null) {
      _curlRepRecords.add(
        CurlRepRecord(
          repIndex: _curlRepRecords.length + 1,
          side: ProfileSide.right,
          view: CurlCameraView.unknown,
          minAngle: minElbowAngle,
          maxAngle: maxElbowAngle,
          source: ThresholdSource.global,
          bucketUpdated: false,
          rejectedOutlier: false,
        ),
      );
      // Feed the in-session push-up auto-calibrator. Convention: top =
      // most-extended (largest elbow angle), bottom = deepest (smallest).
      // Matches `PushUpAutoCalibrator.recordRepExtremes(topAngle, bottomAngle)`.
      // The auto-cal handles its own MAD outlier rejection and emission
      // gating — see `push_up_auto_calibrator.dart`.
      //
      // Calibration-opt-in contract (2026-05-15): the live rep-commit path
      // only feeds the auto-calibrator when the user has explicitly enabled
      // auto-calibration. Manual push-up calibration writes the profile
      // directly via its overlay path and is unaffected by this gate.
      if (_autoCalibrationEnabled) {
        _pushUpAutoCalibrator.recordRepExtremes(maxElbowAngle, minElbowAngle);
      }
    }
    // No view-model-side rep-index counter is kept for push-up — the
    // strategy's internal `_repIndexInSet` is the source of truth, passed
    // into `_resolvePushUpThresholds` via the provider callback. Mirrors
    // the curl / squat resolver pattern.
  }

  /// Feeds the in-session auto-calibrator and the persistent squat
  /// bucket with the rep's observed extremes. Extracted from
  /// `_handleSquatRepCommit` per the architecture review — keeps that
  /// method under the 80-LOC decomposition trigger and creates a clean
  /// seam for a future `SquatSessionCoordinator` extraction.
  ///
  /// Null extremes (rare — abandoned reps where one or both weren't
  /// captured) are silently skipped: the auto-cal needs paired
  /// readings and the bucket's `applyRep` would crash on null.
  void _recordSquatExtremes(double? minKneeAngle, double? maxKneeAngle) {
    if (minKneeAngle == null || maxKneeAngle == null) return;
    // Calibration-opt-in contract (2026-05-15): the live rep-commit path
    // NEVER mutates the squat profile or its in-session auto-calibrator
    // unless the user has explicitly enabled auto-calibration. Profile
    // updates outside this gate are reserved for the manual squat
    // calibration overlay (`_completeSquatCalibration`).
    if (!_autoCalibrationEnabled) return;
    _squatAutoCalibrator.recordRepExtremes(minKneeAngle, maxKneeAngle);
    final profile = _squatProfile;
    if (profile != null) {
      final bucket = profile.bucket ?? squat_profile.SquatRomBucket.empty();
      bucket.applyRep(minKneeAngle, maxKneeAngle);
      profile.bucket = bucket;
      // Dirty unconditionally — `applyRep` always mutates the FIFO
      // recent-samples buffers and the shrink-confirm counters, even on
      // rejectedOutlier / shrinkPending outcomes. Skipping those
      // mutations on save would weaken the shrink-detection guarantee.
      _squatProfileDirty = true;
    } else {
      // First-time user with no profile yet: seed one in memory so
      // future reps can accumulate. Save-on-session-end will persist it.
      final bucket = squat_profile.SquatRomBucket.empty();
      bucket.applyRep(minKneeAngle, maxKneeAngle);
      _squatProfile = squat_profile.SquatRomProfile(bucket: bucket);
      _squatProfileDirty = true;
    }
  }

  /// Tier-priority squat threshold resolver. Called once per rep at the
  /// IDLE→DESCENDING edge; the result is locked for the rest of that rep
  /// (threshold-lock invariant — mirrors curl's `_resolveThresholds`).
  ///
  /// Tier 1 — personal profile bucket if calibrated.
  /// Tier 2 — in-session auto-calibrator after ≥ 2 viable reps.
  /// Tier 3 — cold-start defaults, modified by the session's
  ///          `FeedbackSensitivity`.
  @visibleForTesting
  SquatRomThresholdSet resolveSquatThresholds(int repIndexInSet) =>
      _resolveSquatThresholds(repIndexInSet);

  /// Public test seam for the curl resolver. Same shape as
  /// `resolveSquatThresholds` — exposes the private three-tier walk
  /// (`_resolveThresholds`) so unit tests can pin every (tier × sensitivity)
  /// combination without driving the full pose pipeline.
  ///
  /// Production callers use the private method via the
  /// `curlThresholdsProvider` injection into `RepCounter`.
  @visibleForTesting
  RomThresholds resolveCurlThresholds(
    ProfileSide side,
    CurlCameraView view,
    int repInSet,
  ) => _resolveThresholds(side, view, repInSet);

  /// Test seam: seed the curl profile so the Tier-1 calibrated path can be
  /// exercised. Production code paths load the profile via
  /// `_profileRepository.loadCurl()` during `init()`.
  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void seedCurlProfileForTest(CurlRomProfile profile) {
    _profile = profile;
  }

  /// Test seam: feed the curl in-session auto-cal so Tier-2 can be exercised
  /// without driving the full rep pipeline. Mirrors `seedSquatAutoCalForTest`.
  @visibleForTesting
  void seedCurlAutoCalForTest(double minAngle, double maxAngle, int repCount) {
    for (var i = 0; i < repCount; i++) {
      _autoCalibrator.recordRepExtremes(minAngle, maxAngle);
    }
  }

  /// Test seam: seed the squat profile so the tier-1 path can be
  /// exercised under unit tests. Production code paths load the profile
  /// via `_profileRepository.loadSquat()` during `init()`.
  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void seedSquatProfileForTest(squat_profile.SquatRomProfile profile) {
    _squatProfile = profile;
  }

  /// Test seam: feed the in-session auto-cal so tier-2 can be exercised
  /// without driving the full rep pipeline.
  @visibleForTesting
  void seedSquatAutoCalForTest(double minKnee, double maxKnee, int repCount) {
    _squatAutoCalibrator.reset();
    for (var i = 0; i < repCount; i++) {
      _squatAutoCalibrator.recordRepExtremes(minKnee, maxKnee);
    }
  }

  /// Test seam: enter `WorkoutPhase.calibration` without the camera
  /// stream. Used by `workout_view_model_squat_calibration_test.dart` to
  /// exercise the squat calibration FSM in isolation.
  ///
  /// Skips the camera/pose path entirely — production calibration enters
  /// via `init()` when `forceCalibration` is true.
  @visibleForTesting
  void enterCalibrationForTest() => _enterCalibration();

  /// Test seam: simulate a single calibration rep arriving from the
  /// `RepBoundaryDetector`. Drives the same path the live stream would
  /// (rep gating + counter + completion trigger).
  @visibleForTesting
  void ingestCalibrationRepForTest({
    required double minAngle,
    required double maxAngle,
  }) {
    _onCalibrationRep(RepExtreme(minAngle: minAngle, maxAngle: maxAngle));
  }

  /// Test seam: fire the calibration timeout immediately. Production
  /// path runs a 1-second `Timer.periodic`; tests don't want to wait.
  @visibleForTesting
  void timeoutCalibrationForTest() {
    final message = exercise == ExerciseType.pushUp
        ? "Couldn't complete calibration — try again or skip."
        : "Didn't see any reps — try again or skip.";
    _failCalibration(message);
  }

  /// Test seam: pin the curl view detector to a known value so
  /// `_completeCalibration` can compute the bucket key without running
  /// the live view-detector pipeline.
  @visibleForTesting
  void setDetectedCurlViewForTest(CurlCameraView view) {
    _detectedCurlView = view;
  }

  /// Test seam: hydrate `_profile` from the configured profile repository
  /// without running `init()` (which would also boot camera/pose). Used
  /// by Global Calibration tests that need the duplicate-at-save guard
  /// to see a pre-seeded calibrated bucket.
  @visibleForTesting
  Future<void> loadCurlProfileForTest() async {
    _profile = await _profileRepository.loadCurl() ?? CurlRomProfile();
  }

  SquatRomThresholdSet _resolveSquatThresholds(int repIndexInSet) {
    // Diagnostic short-circuit: every rep gets unmodified tier-3 globals
    // so the `squat.rep` log is uniformly tagged
    // `source=global tier=3 diagnostic=true`. Skips both the calibrated-
    // profile path and the auto-cal path. Mirrors the curl resolver's
    // `diagnosticDisableAutoCalibration` short-circuit at line ~789.
    //
    // Triggered by EITHER the debug-session pref (silent observation mode,
    // ring buffer expanded, frame-metrics emitted) OR the Settings-level
    // unified "Disable auto-calibration" toggle (feedback still ON, ring
    // buffer untouched — same threshold contract, different UX). As of
    // 2026-05-15 that toggle is global — one switch, all three exercises.
    //
    // No sensitivity post-pass — debug sessions collect baseline data
    // against the unmodified High anchor the derivation script expects.
    // Applying sensitivity would make the measurements circular.
    final squatDiagnosticActive =
        (kSquatDebugSessionEnabled && _isSquatDebugSession) ||
        _diagnosticDisableAutoCalibration;
    if (squatDiagnosticActive) {
      final t = SquatRomThresholdSet.anchor;
      _logSquatThresholdsResolved(
        tier: 3,
        source: 'global',
        thresholds: t,
        extra: 'diagnostic=true',
      );
      return t;
    }
    // Tier 1 — personal profile.
    final profile = _squatProfile;
    if (profile != null && profile.isCalibrated) {
      final b = profile.bucket!;
      final highAnchor = SquatRomThresholdSet(
        startAngle: b.observedMaxKneeAngle - kSquatProfileStartMargin,
        bottomAngle: b.observedMinKneeAngle + kSquatProfileBottomMargin,
        endAngle: b.observedMaxKneeAngle - kSquatProfileEndMargin,
      );
      final t = highAnchor.applySensitivity(_feedbackSensitivity);
      _logSquatThresholdsResolved(
        tier: 1,
        source: 'calibrated',
        thresholds: t,
        extra: 'samples=${b.sampleCount}',
      );
      return t;
    }
    // Tier 2 — in-session auto-cal. Gated by the user-facing
    // auto-calibration preference (2026-05-15 split).
    if (_autoCalibrationEnabled) {
      final auto = _squatAutoCalibrator.currentThresholds;
      if (auto != null) {
        final t = auto.applySensitivity(_feedbackSensitivity);
        _logSquatThresholdsResolved(
          tier: 2,
          source: 'autoCalibrated',
          thresholds: t,
          extra: 'reps=${_squatAutoCalibrator.repCount}',
        );
        return t;
      }
    }
    // Tier 3 — cold-start, sensitivity-modified.
    final t = SquatRomThresholdSet.anchor.applySensitivity(
      _feedbackSensitivity,
    );
    _logSquatThresholdsResolved(tier: 3, source: 'global', thresholds: t);
    return t;
  }

  void _logSquatThresholdsResolved({
    required int tier,
    required String source,
    required SquatRomThresholdSet thresholds,
    String? extra,
  }) {
    TelemetryLog.instance.log(
      'squat.thresholds_resolved',
      'tier=$tier source=$source '
          'sensitivity=${_feedbackSensitivity.name} '
          'start=${thresholds.startAngle.toStringAsFixed(2)} '
          // NOTE: `bottom_tuple` is the resolved SquatRomThresholdSet's
          // bottomAngle field — DEFINED BUT NOT ENFORCED at FSM-transition
          // time (the FSM gates on `_effectiveBottomAngle`, logged as
          // `effective_bottom=` on the `squat.rep` line). Kept here for
          // parser continuity; do NOT use it as the depth gate in
          // threshold derivation — use `squat.rep effective_bottom=`.
          'bottom_tuple=${thresholds.bottomAngle.toStringAsFixed(2)} '
          'end=${thresholds.endAngle.toStringAsFixed(2)}'
          '${extra != null ? ' $extra' : ''}',
    );
  }

  /// Resolve push-up thresholds for the next rep. Synchronous (no I/O) —
  /// invoked from `PushUpStrategy.tick` at the IDLE → DESCENDING
  /// transition. Mirrors `_resolveSquatThresholds`.
  ///
  /// Tier precedence (matches the truth table in `.agent_brain/SKILLS.md`,
  /// "Push-up Calibration Tier Precedence"):
  ///   1. Global diagnostic toggle ON → tier 3 defaults UNMODIFIED
  ///      (sensitivity NOT applied — diagnostic baseline is the contract
  ///      the telemetry-derivation pipeline expects).
  ///   2. Calibrated profile present → tier 1 (profile.thresholds, +sens).
  ///   3. Auto-cal has emitted thresholds → tier 2 (+sens).
  ///   4. Otherwise → tier 3 defaults (+sens).
  PushUpRomThresholds _resolvePushUpThresholds(int repIndexInSet) {
    // Push-up debug session — highest-priority override. Forces tier-3
    // `PushUpRomThresholds.defaults` UNMODIFIED (no sensitivity post-pass)
    // so the offline derivation pipeline gets a clean baseline. Mirrors the
    // squat resolver's `_isSquatDebugSession` short-circuit and matches the
    // truth-table row in `.agent_brain/SKILLS.md` (Push-up Calibration Tier
    // Precedence). Checked BEFORE the global diagnostic toggle because a
    // debug session is the most specific intent.
    if (kPushUpDebugSessionEnabled && _isPushUpDebugSession) {
      const t = PushUpRomThresholds.defaults;
      _logPushUpThresholdsResolved(
        tier: 3,
        source: 'global',
        thresholds: t,
        repIndex: repIndexInSet,
        extra: 'debug=true',
      );
      return t;
    }
    if (_diagnosticDisableAutoCalibration) {
      const t = PushUpRomThresholds.defaults;
      _logPushUpThresholdsResolved(
        tier: 3,
        source: 'global',
        thresholds: t,
        repIndex: repIndexInSet,
        extra: 'diagnostic=true',
      );
      return t;
    }
    final profile = _pushUpProfile;
    if (profile != null && profile.isCalibrated) {
      final t = profile.thresholds.applySensitivity(_feedbackSensitivity);
      _logPushUpThresholdsResolved(
        tier: 1,
        source: 'calibrated',
        thresholds: t,
        repIndex: repIndexInSet,
        extra: 'samples=${profile.sampleCount}',
      );
      return t;
    }
    // Tier 2 — gated by the user-facing auto-calibration preference
    // (2026-05-15 split).
    if (_autoCalibrationEnabled) {
      final auto = _pushUpAutoCalibrator.currentThresholds;
      if (auto != null) {
        final t = auto.applySensitivity(_feedbackSensitivity);
        _logPushUpThresholdsResolved(
          tier: 2,
          source: 'autoCalibrated',
          thresholds: t,
          repIndex: repIndexInSet,
          extra: 'reps=${_pushUpAutoCalibrator.repCount}',
        );
        return t;
      }
    }
    final t = PushUpRomThresholds.defaults.applySensitivity(
      _feedbackSensitivity,
    );
    _logPushUpThresholdsResolved(
      tier: 3,
      source: 'global',
      thresholds: t,
      repIndex: repIndexInSet,
    );
    return t;
  }

  void _logPushUpThresholdsResolved({
    required int tier,
    required String source,
    required PushUpRomThresholds thresholds,
    required int repIndex,
    String? extra,
  }) {
    TelemetryLog.instance.log(
      'push_up.thresholds_resolved',
      'tier=$tier source=$source '
          'sensitivity=${_feedbackSensitivity.name} '
          'start=${thresholds.startAngle.toStringAsFixed(2)} '
          'bottom=${thresholds.bottomAngle.toStringAsFixed(2)} '
          'shallowRepMax=${thresholds.shallowRepMaxAngle.toStringAsFixed(2)} '
          'end=${thresholds.endAngle.toStringAsFixed(2)} '
          'rep_index=$repIndex'
          '${extra != null ? ' $extra' : ''}',
    );
  }

  /// Fires once per session when the anatomical classifier locks a ratio
  /// above [kLongFemurRatioThreshold]. Logged for telemetry-driven
  /// dataset analysis; also stamped into the user's profile bucket so
  /// future sessions can seed the classifier via `seedFromPersisted`.
  void _handleSquatLongFemurDetected(double medianRatio) {
    TelemetryLog.instance.log(
      'squat.anatomical_long_femur',
      'median_ratio=${medianRatio.toStringAsFixed(3)} '
          'threshold=$kLongFemurRatioThreshold',
    );
    final profile = _squatProfile;
    if (profile?.bucket != null) {
      profile!.bucket!.femurTorsoRatio = medianRatio;
      _squatProfileDirty = true;
    }
  }

  static FormError _cooldownKeyFor(FormError err) => switch (err) {
    FormError.asymmetryLeftLag ||
    FormError.asymmetryRightLag => FormError.asymmetryLeftLag,
    _ => err,
  };

  static String _errorMessage(FormError err) => switch (err) {
    FormError.torsoSwing => "No swinging",
    FormError.depthSwing => "Don't rock forward",
    FormError.shoulderArc => "Stop rotating",
    FormError.elbowDrift => 'Keep your elbow still',
    FormError.elbowRise => 'Elbow down',
    FormError.shoulderShrug => 'Keep your shoulders down',
    FormError.backLean => "Don't lean back",
    FormError.shortRomStart => 'Full extension down',
    FormError.shortRomPeak => 'Curl all the way up',
    FormError.squatDepth => 'Go deeper',
    FormError.trunkTibia => 'Keep your chest up',
    FormError.excessiveForwardLean => 'Chest up — keep your back tall',
    FormError.excessiveBackwardLean =>
      'Stop leaning back — stack ribs over hips',
    FormError.heelLift => 'Drive your heels into the floor',
    FormError.hipLead => 'Lead with your chest',
    FormError.noKneeFlexion => 'Sit into the squat — bend your knees',
    FormError.hipsForwardOnDescent => 'Push your hips back',
    FormError.kneeLedDescent =>
      'Sit back — lead with your hips, not your knees',
    FormError.kneeDominantPattern => 'Keep your heels down and weight mid-foot',
    // forwardKneeShift intentionally has a fallback string — TTS suppression
    // happens in `_onFormErrors`, not here. The string is still used by the
    // visual highlight subtitle if the in-workout overlay surfaces it.
    FormError.forwardKneeShift => 'Knees tracking forward',
    FormError.hipSag => 'Keep your body straight',
    FormError.pushUpShortRom => 'Go lower',
    FormError.eccentricTooFast => 'Lower slowly',
    FormError.concentricTooFast => 'Control the lift',
    FormError.tempoInconsistent => 'Keep steady tempo',
    FormError.asymmetryLeftLag => 'Left arm is lagging',
    FormError.asymmetryRightLag => 'Right arm is lagging',
    FormError.fatigue => "You're slowing down, stay strong",
    // Squat tempo/fatigue (2026-05-16, curl-parity). Same biomechanical
    // instruction as the curl cues — the message is movement-agnostic; the
    // per-exercise enum exists only so summary/telemetry stay unambiguous.
    FormError.squatEccentricTooFast => 'Lower slowly',
    FormError.squatConcentricTooFast => 'Control the drive up',
    FormError.squatTempoInconsistent => 'Keep steady tempo',
    FormError.squatFatigue => "You're slowing down, stay strong",
    // Push-up tempo/fatigue (2026-05-16, curl-parity).
    FormError.pushUpEccentricTooFast => 'Lower slowly',
    FormError.pushUpConcentricTooFast => 'Control the press',
    FormError.pushUpTempoInconsistent => 'Keep steady tempo',
    FormError.pushUpFatigue => "You're slowing down, stay strong",
    FormError.plankArmAngle => 'Stack shoulders over elbows',
    FormError.plankBodyLine => 'Keep your back and hips straight',
  };

  /// Per-error highlight color. `forwardKneeShift` is informational (no TTS,
  /// no quality penalty) and uses a dimmer orange to distinguish it from
  /// active-cue errors — plan flow-decision #6. All other errors share the
  /// existing red palette.
  static Color _highlightColorFor(FormError err) =>
      err == FormError.forwardKneeShift
      ? const Color(0xFFFFA726) // orange.shade400 equivalent
      : Colors.redAccent;

  void _triggerHighlight(FormError err) {
    final landmarks = _errorLandmarks[err];
    if (landmarks == null) return;
    final color = _highlightColorFor(err);
    _highlightTimer?.cancel();
    _errorHighlight = {for (final idx in landmarks) idx: color};
    notifyListeners();
    _highlightTimer = Timer(Duration(milliseconds: kHighlightDurationMs), () {
      _errorHighlight = {};
      notifyListeners();
    });
  }

  bool _canSpeakOcclusionPrompt() {
    if (_lastOcclusionTts == null) return true;
    return DateTime.now().difference(_lastOcclusionTts!).inSeconds >=
        kFeedbackCooldownSec;
  }

  // ── Session actions ───────────────────────────────────
  void startNextSet() {
    _repCounter.nextSet();
    // Reset the squat auto-calibrator on set rollover — squat has no
    // view-lock concept, so the set boundary is the only reset trigger
    // (mirrors curl's per-set reset). Tier 1 (profile) survives.
    _squatAutoCalibrator.reset();
    // Same contract for push-up — rested-between-sets shifts the
    // observed ROM so the prior window's anchor no longer applies.
    _pushUpAutoCalibrator.reset();
    _snapshot = RepSnapshot(
      reps: 0,
      sets: _snapshot.sets + 1,
      state: RepState.idle,
    );
    notifyListeners();
  }

  void finishWorkout() => _triggerCompleted();

  /// Triggered from the in-workout calibration sheet. Works from setupCheck,
  /// countdown, or active — tears down any in-flight calibration resources
  /// and re-enters the phase. Session rep state is preserved.
  void startInWorkoutCalibration() {
    _disposeCalibrationResources();
    _enterCalibration();
  }

  /// Same signal the gear-icon badge uses: profile missing OR no bucket
  /// reached calibration minimum samples.
  bool needsCalibrationHint() {
    if (exercise == ExerciseType.pushUp) {
      return _pushUpProfile == null || !_pushUpProfile!.isCalibrated;
    }
    if (!exercise.isCurl) return false;
    final profile = _profile;
    if (profile == null) return true;
    if (profile.buckets.isEmpty) return true;
    return !profile.buckets.values.any(
      (b) => b.sampleCount >= kCalibrationMinReps,
    );
  }

  bool get asymmetryDetected =>
      _lastFeedbackTime.containsKey(FormError.asymmetryLeftLag);

  void _triggerCompleted() {
    if (_phase == WorkoutPhase.completed) return; // guard double-fire
    final duration = _activeStart != null
        ? DateTime.now().difference(_activeStart!)
        : Duration.zero;
    _phase = WorkoutPhase.completed;
    notifyListeners();
    final repConcentricMs = _repConcentricDurations
        .map((d) => d?.inMilliseconds)
        .toList(growable: false);
    final repDepthPercents = _computeLiveRepDepthPercents();
    final event = WorkoutCompletedEvent(
      exercise: exercise,
      totalReps: _snapshot.reps,
      totalSets: _snapshot.sets,
      sessionDuration: duration,
      averageQuality: _snapshot.averageQuality,
      detectedView: _snapshot.detectedView,
      repQualities: _snapshot.repQualities,
      fatigueDetected: _snapshot.fatigueDetected,
      asymmetryDetected: asymmetryDetected,
      eccentricTooFastCount: _snapshot.eccentricTooFastCount,
      errorsTriggered: _lastFeedbackTime.keys.toSet(),
      errorCounts: Map.unmodifiable(_formErrorCounts),
      curlRepRecords: List.unmodifiable(_curlRepRecords),
      curlBucketSummaries: _snapshotBucketsForSummary(),
      squatVariant: _squatVariant,
      squatLongFemurLifter: _squatLongFemurLifter,
      squatRepMetrics: List<SquatRepMetrics>.unmodifiable(_squatRepMetrics),
      bicepsSideRepMetrics: List<BicepsSideRepMetrics>.unmodifiable(
        _bicepsSideRepMetrics,
      ),
      curlProfile: _profile,
      pushUpProfile: _pushUpProfile,
      // Snapshot the auto-calibrator's final state for the Form Audit's
      // Tier-2 bar. May be null when fewer than 2 reps were observed or
      // the observed ROM excursion was below kMinViableRomDegrees.
      autoCalSnapshot: _autoCalibrator.currentThresholds,
      feedbackSensitivity: _feedbackSensitivity,
      repConcentricMs: List<int?>.unmodifiable(repConcentricMs),
      repDepthPercents: List<double?>.unmodifiable(repDepthPercents),
      // Squat-only bundle for the post-session Form Audit. Null for
      // non-squat sessions so the curl/push-up branches in
      // `SummaryScreen._buildFormAuditCard` aren't perturbed. The audit
      // resolver consumes `profile`, `autoCalSnapshot`, and
      // `feedbackSensitivity` to grade each rep against the most
      // personalized ROM bar available (Tier 1 → Tier 2 → Tier 3).
      squatContext: exercise == ExerciseType.squat
          ? SquatSessionContext(
              variant: _squatVariant,
              longFemurLifter: _squatLongFemurLifter,
              feedbackSensitivity: _feedbackSensitivity,
              profile: _squatProfile,
              autoCalSnapshot: _squatAutoCalibrator.currentThresholds,
            )
          : null,
    );
    // Save first, then emit so Home/History reloads see the inserted row.
    unawaited(_persistThenEmitCompletion(event, _activeStart ?? DateTime.now()));
  }

  Future<void> _persistThenEmitCompletion(
    WorkoutCompletedEvent event,
    DateTime startedAt,
  ) async {
    await _persistCompletedSession(event, startedAt);
    if (_completionCtrl.isClosed) return;
    _completionCtrl.add(event);
  }

  Future<void> _persistCompletedSession(
    WorkoutCompletedEvent event,
    DateTime startedAt,
  ) async {
    try {
      await _sessionRepository.insertCompletedSession(
        event,
        startedAt: startedAt,
        concentricDurations: List<Duration?>.unmodifiable(
          _repConcentricDurations,
        ),
      );
    } catch (e, st) {
      TelemetryLog.instance.log(
        'session.save_failed',
        e.toString(),
        data: <String, Object?>{'stackTrace': st.toString()},
      );
    }
  }

  // ── Dispose ───────────────────────────────────────────
  @override
  void dispose() {
    _countdownTimer?.cancel();
    _highlightTimer?.cancel();
    _uncalibratedNoticeTimer?.cancel();
    _viewFlipBannerTimer?.cancel();
    _disposeCalibrationResources();
    // Best-effort persistence — fire-and-forget.
    _flushProfileIfDirty();
    _flushSquatProfileIfDirty();
    // Restore the default telemetry ring-buffer cap if this was a debug
    // session. No-op for normal sessions (resetCap is idempotent).
    if (kCurlDebugSessionEnabled && _isCurlDebugSession) {
      TelemetryLog.instance.resetCap();
    }
    if (kSquatDebugSessionEnabled && _isSquatDebugSession) {
      TelemetryLog.instance.resetCap();
    }
    if (kPushUpDebugSessionEnabled && _isPushUpDebugSession) {
      TelemetryLog.instance.resetCap();
    }
    _tts.dispose();
    _camera.dispose();
    _pose.dispose();
    _completionCtrl.close();
    super.dispose();
  }
}
