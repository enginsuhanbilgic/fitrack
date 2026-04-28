import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/form_thresholds.dart';
import '../core/squat_form_thresholds.dart';
import '../core/platform_config.dart';
import '../core/rom_thresholds.dart';
import '../core/types.dart';
import '../engine/angle_utils.dart';
import '../engine/curl/curl_auto_calibrator.dart';
import '../engine/curl/curl_rom_profile.dart';
import '../engine/curl/rep_boundary_detector.dart';
import '../engine/landmark_smoother.dart';
import '../engine/rep_counter.dart';
import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import '../services/camera_service.dart';
import '../services/db/preferences_repository.dart';
import '../services/db/profile_repository.dart';
import '../services/db/session_repository.dart';
import '../services/reference_reps/reference_rep_source.dart';
import '../services/pose/mlkit_pose_service.dart';
import '../services/pose/pose_service.dart';
import '../services/telemetry_log.dart';
import '../services/tts_service.dart';

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

  /// Per-rep DTW similarity scores (0.0–1.0). Empty or all-null = card hidden.
  final List<double?> dtwSimilarities;

  /// Squat variant the session ran with. `bodyweight` for non-squat sessions.
  final SquatVariant squatVariant;

  /// True if the "Tall lifter" toggle was on for this session.
  final bool squatLongFemurLifter;

  /// Per-rep squat metrics, index-aligned with the rep order. Empty for
  /// non-squat sessions.
  final List<SquatRepMetrics> squatRepMetrics;

  /// Per-rep biceps-curl side-view metrics, index-aligned with the rep
  /// order. Empty for non-side-view sessions (front curl, squat, push-up).
  final List<BicepsSideRepMetrics> bicepsSideRepMetrics;

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
    this.dtwSimilarities = const [],
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
    this.repConcentricMs = const [],
    this.repDepthPercents = const [],
  });
}

/// Post-calibration summary card payload.
class CalibrationSummary {
  final String viewLabel;
  final String sidesLabel;
  const CalibrationSummary({required this.viewLabel, required this.sidesLabel});
}

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

  /// Form/ROM coaching sensitivity for biceps curl. Read from
  /// [PreferencesRepository.getCurlSensitivity] during [init] and frozen
  /// for the session (snapshot-on-construction). Affects only cold-start
  /// (`ThresholdSource.global`) reps — calibrated and auto-calibrated paths
  /// are unaffected.
  CurlSensitivity _curlSensitivity = CurlSensitivity.medium;

  /// Form sensitivity for squat. Read from [PreferencesRepository.getSquatSensitivity]
  /// during [init] and frozen for the session (snapshot-on-construction).
  SquatSensitivity _squatSensitivity = SquatSensitivity.medium;

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
  final ReferenceRepSource _referenceRepSource;
  late final RepCounter _repCounter;

  // ── Engine ─────────────────────────────────────────────
  final LandmarkSmoother _displaySmoother = LandmarkSmoother(
    minCutoff: kOneEuroDisplayMinCutoff,
    beta: kOneEuroDisplayBeta,
    dCutoff: kOneEuroDisplayDCutoff,
  );
  CurlRomProfile? _profile;
  final CurlAutoCalibrator _autoCalibrator = CurlAutoCalibrator();
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

  // ── Lifecycle / phase ──────────────────────────────────
  bool _isReady = false;
  bool _isProcessing = false;
  String? _error;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  WorkoutPhase _phase = WorkoutPhase.setupCheck;

  // SETUP_CHECK.
  int _setupOkFrames = 0;
  Map<int, Color> _landmarkColors = {};

  // COUNTDOWN.
  int _countdownValue = kCountdownSeconds;
  Timer? _countdownTimer;

  // ACTIVE.
  DateTime? _absenceStart;
  DateTime? _activeStart;
  final Map<FormError, DateTime> _lastFeedbackTime = {};
  final Map<FormError, int> _formErrorCounts = {};

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
  Timer? _uncalibratedNoticeTimer;

  // Runtime view-flip advisory banner. Set whenever the engine reports
  // [CurlStrategy.onViewFlipped]; auto-cleared after 2s.
  String? _viewFlipBannerText;
  Timer? _viewFlipBannerTimer;
  static const Duration _kViewFlipBannerDuration = Duration(seconds: 2);

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

  /// Per-rep DTW similarity scores (T5.3), index-aligned with _curlRepRecords.
  final List<double?> _repDtwSimilarities = [];

  /// Angle buffer for the current in-progress rep. Filled per frame while the
  /// FSM is in CONCENTRIC/PEAK/ECCENTRIC; cleared on IDLE→CONCENTRIC and on
  /// commit. Scored against the reference in [_handleCurlRepCommit].
  final List<double> _currentRepAngles = [];

  /// Set in [init] from [PreferencesRepository]. Immutable for the session.
  bool _dtwScoringEnabled = false;

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

  /// Monotonic rep index for squat.rep telemetry lines.
  int _squatDebugRepIndex = 0;

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
    FormError.forwardKneeShift: [LM.leftKnee, LM.rightKnee],
    FormError.heelLift: [LM.leftHeel, LM.rightHeel],
    // trunkTibia retained — legacy session rendering path.
    FormError.trunkTibia: [LM.leftHip, LM.rightHip],
  };

  WorkoutViewModel({
    required this.exercise,
    required ProfileRepository profileRepository,
    required SessionRepository sessionRepository,
    required PreferencesRepository preferencesRepository,
    this.forceCalibration = false,
    this.curlSide = ExerciseSide.both,
    CameraService? camera,
    PoseService? pose,
    TtsService? tts,
    ReferenceRepSource? referenceRepSource,
  }) : _camera = camera ?? CameraService(),
       _pose = pose ?? MlKitPoseService(),
       _tts = tts ?? TtsService(),
       _profileRepository = profileRepository,
       _sessionRepository = sessionRepository,
       _preferencesRepository = preferencesRepository,
       _referenceRepSource =
           referenceRepSource ?? const ConstReferenceRepSource();

  // ── Public read-only getters (widget-observable state) ──
  bool get isReady => _isReady;
  String? get error => _error;
  WorkoutPhase get phase => _phase;
  int get setupOkFrames => _setupOkFrames;
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
  CalibrationSummary? get calibrationSummary => _calibrationSummary;

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
      List<double>? referenceAngles;
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
        _curlSensitivity = await _preferencesRepository.getCurlSensitivity();
        // Diagnostic flag — snapshot once, identical to other curl prefs.
        // A mid-session toggle in Settings has no effect on this run (matches
        // the squat long-femur "snapshot-on-construction" rule).
        _diagnosticDisableAutoCalibration = await _preferencesRepository
            .getDiagnosticDisableAutoCalibration();
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
                  'sensitivity=${_curlSensitivity.name} '
                  'thresholds_start=${debugThresholds.startAngle.toStringAsFixed(1)} '
                  'thresholds_peak=${debugThresholds.peakAngle.toStringAsFixed(1)} '
                  'thresholds_peak_exit=${debugThresholds.peakExitAngle.toStringAsFixed(1)} '
                  'thresholds_end=${debugThresholds.endAngle.toStringAsFixed(1)} '
                  'use_manual_overrides=$kUseManualOverrides '
                  'use_data_driven=$kUseDataDrivenThresholds',
            );
          }
        }
        if (_diagnosticDisableAutoCalibration) {
          TelemetryLog.instance.log(
            'diagnostic.mode_active',
            'auto-calibration disabled — every rep will run on source=global',
          );
        }
        _dtwScoringEnabled = await _preferencesRepository.getEnableDtwScoring();
        if (_dtwScoringEnabled) {
          // View is not yet known at init time; use the detected view once the
          // first frame arrives. For now seed with front:both as the common
          // default — WorkoutViewModel updates _referenceAngles on first
          // view-lock via _onViewLocked (below).
          referenceAngles = _referenceRepSource.forBucket(CurlCameraView.front);
        }
      } else if (exercise == ExerciseType.squat) {
        // Snapshot squat preferences before constructing RepCounter so the
        // strategy + analyzer freeze on the values that were active at
        // workout start. Mid-session Settings changes apply to the next
        // workout (plan flow-decision #2).
        _squatVariant = await _preferencesRepository.getSquatVariant();
        _squatLongFemurLifter = await _preferencesRepository
            .getSquatLongFemurLifter();
        _squatSensitivity = await _preferencesRepository.getSquatSensitivity();
        if (kSquatDebugSessionEnabled) {
          _isSquatDebugSession = await _preferencesRepository
              .getSquatDebugSession();
          if (_isSquatDebugSession) {
            TelemetryLog.instance.setCap(kSquatDebugRingBufferSize);
            TelemetryLog.instance.log(
              'squat_debug.session_active',
              'ring_buffer=$kSquatDebugRingBufferSize '
                  'frame_metrics@${kSquatDebugFrameMetricsHz}Hz',
            );
            TelemetryLog.instance.log(
              'squat_debug.session_start',
              'ts=${DateTime.now().toIso8601String()} '
                  'exercise=${exercise.name} '
                  'variant=${_squatVariant.name} '
                  'long_femur=$_squatLongFemurLifter '
                  'start_angle=$kSquatStartAngle '
                  'bottom_angle=$kSquatBottomAngle '
                  'end_angle=$kSquatEndAngle '
                  'lean_warn_bodyweight=$kSquatLeanWarnDegBodyweight '
                  'lean_warn_hbbs=$kSquatLeanWarnDegHBBS '
                  'knee_shift_warn=$kSquatKneeShiftWarnRatio '
                  'heel_lift_warn=$kSquatHeelLiftWarnRatio',
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
        curlHistoricalConcentricDurations: historical,
        curlReferenceRepAngleSeries: referenceAngles,
        curlEnableDtwScoring: _dtwScoringEnabled,
        curlFormThresholds: FormThresholds.forSensitivity(_curlSensitivity),
        squatVariant: _squatVariant,
        squatLongFemurLifter: _squatLongFemurLifter,
        squatFormThresholds: SquatFormThresholds.forSensitivity(
          _squatSensitivity,
        ),
        onSquatRepCommit: _handleSquatRepCommit,
      );
      if (exercise.isCurl && forceCalibration) {
        // Personal calibration is opt-in only — Settings → Recalibrate sets
        // `forceCalibration`. We never launch it automatically.
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
      // against the unmodified global thresholds the Python script was
      // calibrated with. Applying sensitivity would make the measurements
      // circular.
      return RomThresholds.global(view);
    }
    final profile = _profile;
    if (profile != null && view != CurlCameraView.unknown) {
      final bucket = profile.bucketFor(side, view);
      if (bucket != null && bucket.sampleCount >= kCalibrationMinReps) {
        return RomThresholds.fromBucket(
          bucket,
          warmup: repInSet < kProfileWarmupReps,
        );
      }
    }
    final auto = _autoCalibrator.currentThresholds;
    if (auto != null) return auto;
    // Cold-start path: sensitivity applies here only.
    return RomThresholds.global(view, _curlSensitivity);
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
    _autoCalibrator.recordRepExtremes(minAngle, maxAngle);
    final profile = _profile;
    if (profile == null) return;
    final bucket = profile.bucketFor(side, view) ?? RomBucket.empty(side, view);
    final result = bucket.applyRep(minAngle, maxAngle);
    profile.upsertBucket(bucket);
    _profileDirty = true;

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

    // DTW score for this rep (null when scoring disabled or no reference).
    // scoreRep() lives on the analyzer, but the angle buffer is host-owned
    // (engine stays Flutter-free). We pass the captured buffer here.
    final dtwScore = _repCounter.scoreCurlRep(
      List<double>.unmodifiable(_currentRepAngles),
    );
    _repDtwSimilarities.add(dtwScore?.similarity);
    _currentRepAngles.clear();

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

    TelemetryLog.instance.log(
      'profile.update',
      'side=${side.name} view=${view.name} result=${result.name} '
          'samples=${bucket.sampleCount} '
          'min=${bucket.observedMinAngle.toStringAsFixed(1)} '
          'max=${bucket.observedMaxAngle.toStringAsFixed(1)}',
    );

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
          'result=${result.name}',
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

  // ── Calibration phase ─────────────────────────────────
  void _enterCalibration() {
    _phase = WorkoutPhase.calibration;
    _calibrationReps = 0;
    _calibrationSecondsRemaining = kCalibrationTimeoutSec;
    _calibrationError = null;
    _calibrationCurrentAngle = null;
    _calibrationCollected.clear();
    _calibrationDetector = RepBoundaryDetector();
    _calibrationSub = _calibrationDetector!.extremes.listen(_onCalibrationRep);
    TelemetryLog.instance.log('calibration.start', 'phase entered');
    _tts.speak(
      'Curl through your full natural range, $kCalibrationMinReps times.',
    );
    _startCalibrationTimeout();
    notifyListeners();
  }

  void _startCalibrationTimeout() {
    _calibrationTimeoutTimer?.cancel();
    _calibrationTimeoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _calibrationSecondsRemaining--;
      notifyListeners();
      if (_calibrationSecondsRemaining <= 0) {
        t.cancel();
        _failCalibration("Didn't see any reps — try again or skip.");
      }
    });
  }

  void _onCalibrationRep(RepExtreme rep) {
    _calibrationCollected.add(rep);
    _calibrationReps = _calibrationCollected.length;
    notifyListeners();
    if (_calibrationReps >= kCalibrationMinReps) _completeCalibration();
  }

  void _completeCalibration() {
    _calibrationTimeoutTimer?.cancel();
    final lockedView = _detectedCurlView;
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
    // Front view: seed both side buckets symmetrically. Side view: the bucket
    // matching the locked side. Unknown: defer — bucket attribution happens
    // at workout time once view detector locks.
    final sidesToSeed = switch (lockedView) {
      CurlCameraView.front => const [ProfileSide.left, ProfileSide.right],
      CurlCameraView.sideLeft => const [ProfileSide.left],
      CurlCameraView.sideRight => const [ProfileSide.right],
      CurlCameraView.unknown => const <ProfileSide>[],
    };
    for (final s in sidesToSeed) {
      final b = profile.bucketOrEmpty(s, lockedView);
      for (final rep in _calibrationCollected) {
        b.applyRep(rep.minAngle, rep.maxAngle);
      }
      profile.upsertBucket(b);
    }
    _profile = profile;
    _profileDirty = true;
    TelemetryLog.instance.log(
      'calibration.complete',
      'view=${lockedView.name} sides=${sidesToSeed.length} '
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
    final sidesLabel = sidesToSeed.length == 2
        ? 'Left and Right arms'
        : (sidesToSeed.contains(ProfileSide.left) ? 'Left arm' : 'Right arm');
    _calibrationSummary = CalibrationSummary(
      viewLabel: viewLabel,
      sidesLabel: sidesLabel,
    );
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

  void _failCalibration(String reason) {
    _calibrationTimeoutTimer?.cancel();
    TelemetryLog.instance.log('calibration.fail', reason);
    _calibrationError = reason;
    notifyListeners();
  }

  void retryCalibration() {
    _disposeCalibrationResources();
    _enterCalibration();
  }

  void skipCalibration() {
    TelemetryLog.instance.log('calibration.skipped', 'user opted out');
    _exitCalibration(toPhase: WorkoutPhase.setupCheck);
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
    final view = _repCounter.updateSetupView(result);
    if (view != _detectedCurlView) _detectedCurlView = view;

    final angle =
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

    if (angle != null) _calibrationDetector?.onAngle(angle);
    _landmarks = smoothed;
    _calibrationCurrentAngle = angle;
    notifyListeners();
  }

  // ── Frame pipeline ────────────────────────────────────
  void _onFrame(CameraImage image) {
    if (_isProcessing) return;

    final now = DateTime.now();
    final intervalMs = switch (_phase) {
      WorkoutPhase.active => kActiveFrameIntervalMs,
      WorkoutPhase.calibration => kCalibrationFrameIntervalMs,
      _ => kIdleFrameIntervalMs,
    };
    if (now.difference(_lastProcessed).inMilliseconds < intervalMs) return;

    _lastProcessed = now;
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
      final List<int> gatePrimary;
      final List<int>? gateAlt;
      if (isSideCurl) {
        gatePrimary = const [11, 13, 15]; // left arm trio
        gateAlt = const [12, 14, 16]; // right arm trio
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
          : null;
      final Set<int>? gateBestEffort = isSideCurl ? const {15, 16} : null;
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
    } catch (_) {
      // Silently drop bad frames — don't crash the stream.
    }
  }

  // ── SETUP_CHECK ────────────────────────────────────────
  void _updateSetupCheck(PoseResult result, List<PoseLandmark> smoothed) {
    if (exercise.isCurl) {
      final view = _repCounter.updateSetupView(result);
      if (view != _detectedCurlView) _detectedCurlView = view;
    }

    final requirements = ExerciseRequirements.forExercise(exercise);
    final colors = <int, Color>{};
    var allVisible = true;

    // Curl exercises apply a stricter confidence floor during setup to reject
    // bystanders whose landmarks are partially visible at the frame edges.
    final double setupConfidence = exercise.isCurl
        ? kSetupCurlMinConfidence
        : kMinLandmarkConfidence;

    for (final idx in requirements.landmarkIndices) {
      final lm = result.landmark(idx, minConfidence: setupConfidence);
      if (lm != null) {
        colors[idx] = const Color(0xFF00E676);
      } else {
        colors[idx] = Colors.redAccent;
        allVisible = false;
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

    if (allVisible) {
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
    final allVisible = requirements.landmarkIndices.every(
      (idx) =>
          result.landmark(idx, minConfidence: kMinLandmarkConfidence) != null,
    );

    if (!allVisible) {
      _countdownTimer?.cancel();
      _tts.stop();
      _phase = WorkoutPhase.setupCheck;
      _setupOkFrames = 0;
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
    final total = requirements.landmarkIndices.length;
    final visible = requirements.landmarkIndices
        .where(
          (idx) =>
              result.landmark(idx, minConfidence: kMinLandmarkConfidence) !=
              null,
        )
        .length;

    if (visible == total) {
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
      // Rep-commit TTS: one short number per counted rep. Guarded against set
      // reset (where reps rolls back to 0). Suppressed during a debug
      // session — the user explicitly opted into silent observation.
      final isDebugSilent = kCurlDebugSessionEnabled && _isCurlDebugSession;
      if (!isDebugSilent && snapshot.reps > _snapshot.reps) {
        _tts.speak('${snapshot.reps}');
      }
      // Capture angle into the DTW buffer while the rep is in progress.
      // The buffer is consumed + cleared in _handleCurlRepCommit.
      if (_dtwScoringEnabled &&
          exercise.isCurl &&
          snapshot.jointAngle != null &&
          (snapshot.state == RepState.concentric ||
              snapshot.state == RepState.peak ||
              snapshot.state == RepState.eccentric)) {
        _currentRepAngles.add(snapshot.jointAngle!);
      } else if (snapshot.state == RepState.idle &&
          _snapshot.state != RepState.idle) {
        // Transition back to idle without a commit (aborted rep) — clear buffer.
        _currentRepAngles.clear();
      }
      _landmarks = smoothed;
      _snapshot = snapshot;
      notifyListeners();
    } else if (visible > 0) {
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

  // ── Form feedback coordinator ─────────────────────────
  void _onFormErrors(List<FormError> errors) {
    // Curl debug session: silent observation. Skip cooldown bookkeeping,
    // TTS, and visual highlights entirely — the analyzer's per-rep
    // telemetry still fires (we want the data), but nothing reaches the
    // user. `_formErrorCounts` is intentionally NOT incremented either,
    // so the post-session summary doesn't show inflated counts that
    // never had a chance to be seen and corrected mid-set.
    if (kCurlDebugSessionEnabled && _isCurlDebugSession) {
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
      _tts.speak(_errorMessage(err));
      _triggerHighlight(err);
      break; // one cue per update — list order defines priority
    }
  }

  /// Squat-only rep commit callback. Captures per-rep metrics for the
  /// summary screen. Mirrors `_handleCurlRepCommit` but lighter — squat
  /// has no profile/bucket bookkeeping.
  void _handleSquatRepCommit({
    required int repIndex,
    required double? quality,
    required double? leanDeg,
    required double? kneeShiftRatio,
    required double? heelLiftRatio,
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
          'quality=${quality?.toStringAsFixed(3) ?? "null"}',
    );
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
    FormError.heelLift => 'Drive your heels into the floor',
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
      dtwSimilarities: List<double?>.unmodifiable(_repDtwSimilarities),
      squatVariant: _squatVariant,
      squatLongFemurLifter: _squatLongFemurLifter,
      squatRepMetrics: List<SquatRepMetrics>.unmodifiable(_squatRepMetrics),
      bicepsSideRepMetrics: List<BicepsSideRepMetrics>.unmodifiable(
        _bicepsSideRepMetrics,
      ),
      repConcentricMs: List<int?>.unmodifiable(repConcentricMs),
      repDepthPercents: List<double?>.unmodifiable(repDepthPercents),
    );
    // Emit first — the UI's SummaryScreen push is latency-critical and must
    // not wait for a SQLite round-trip. Persistence is fire-and-forget; any
    // failure is logged to telemetry and never crashes the session.
    _completionCtrl.add(event);
    unawaited(_persistCompletedSession(event, _activeStart ?? DateTime.now()));
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
        dtwSimilarities: List<double?>.unmodifiable(_repDtwSimilarities),
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
    // Restore the default telemetry ring-buffer cap if this was a debug
    // session. No-op for normal sessions (resetCap is idempotent).
    if (kCurlDebugSessionEnabled && _isCurlDebugSession) {
      TelemetryLog.instance.resetCap();
    }
    if (kSquatDebugSessionEnabled && _isSquatDebugSession) {
      TelemetryLog.instance.resetCap();
    }
    _tts.dispose();
    _camera.dispose();
    _pose.dispose();
    _completionCtrl.close();
    super.dispose();
  }
}
