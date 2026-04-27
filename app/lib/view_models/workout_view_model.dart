import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/constants.dart';
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
    required this.curlRepRecords,
    required this.curlBucketSummaries,
    this.dtwSimilarities = const [],
    this.squatVariant = SquatVariant.bodyweight,
    this.squatLongFemurLifter = false,
    this.squatRepMetrics = const [],
    this.bicepsSideRepMetrics = const [],
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
        // Diagnostic flag — snapshot once, identical to other curl prefs.
        // A mid-session toggle in Settings has no effect on this run (matches
        // the squat long-femur "snapshot-on-construction" rule).
        _diagnosticDisableAutoCalibration = await _preferencesRepository
            .getDiagnosticDisableAutoCalibration();
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
        squatVariant: _squatVariant,
        squatLongFemurLifter: _squatLongFemurLifter,
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
    return RomThresholds.global(view);
  }

  /// Engine-callback: a view flip just committed at FSM idle. Surface a
  /// 2-second amber advisory so the user sees the system adapt. Mirrors
  /// the existing transient-banner patterns in `WorkoutScreen`.
  void _handleCurlViewFlipped(CurlCameraView from, CurlCameraView to) {
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
              'rep_quality=${extras.lastRepQuality.toStringAsFixed(3)} '
              'concentric_ms=${concentricDuration?.inMilliseconds ?? -1} '
              'source=${resolved.source.name}',
        );
      }
    }
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

    for (final idx in requirements.landmarkIndices) {
      final lm = result.landmark(idx, minConfidence: kMinLandmarkConfidence);
      if (lm != null) {
        colors[idx] = const Color(0xFF00E676);
      } else {
        colors[idx] = Colors.redAccent;
        allVisible = false;
      }
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
      if (snapshot.formErrors.isNotEmpty) _onFormErrors(snapshot.formErrors);
      // Rep-commit TTS: one short number per counted rep. Guarded against set
      // reset (where reps rolls back to 0).
      if (snapshot.reps > _snapshot.reps) {
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
  }

  static FormError _cooldownKeyFor(FormError err) => switch (err) {
    FormError.asymmetryLeftLag ||
    FormError.asymmetryRightLag => FormError.asymmetryLeftLag,
    _ => err,
  };

  static String _errorMessage(FormError err) => switch (err) {
    FormError.torsoSwing => "Don't swing",
    FormError.depthSwing => "Don't rock toward the camera",
    FormError.shoulderArc => "Stop pivoting at the hip",
    FormError.elbowDrift => 'Keep your elbow still',
    FormError.shoulderShrug => 'Keep your shoulders down',
    FormError.backLean => "Don't lean back",
    FormError.shortRomStart => 'Start from full extension',
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
      curlRepRecords: List.unmodifiable(_curlRepRecords),
      curlBucketSummaries: _snapshotBucketsForSummary(),
      dtwSimilarities: List<double?>.unmodifiable(_repDtwSimilarities),
      squatVariant: _squatVariant,
      squatLongFemurLifter: _squatLongFemurLifter,
      squatRepMetrics: List<SquatRepMetrics>.unmodifiable(_squatRepMetrics),
      bicepsSideRepMetrics: List<BicepsSideRepMetrics>.unmodifiable(
        _bicepsSideRepMetrics,
      ),
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
    _tts.dispose();
    _camera.dispose();
    _pose.dispose();
    _completionCtrl.close();
    super.dispose();
  }
}
