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
import '../services/db/profile_repository.dart';
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

  // ── Services ───────────────────────────────────────────
  final CameraService _camera;
  final PoseService _pose;
  final TtsService _tts;
  final ProfileRepository _profileRepository;
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
  Timer? _uncalibratedNoticeTimer;

  // Per-frame display state.
  List<PoseLandmark> _landmarks = [];
  RepSnapshot _snapshot = const RepSnapshot(
    reps: 0,
    sets: 1,
    state: RepState.idle,
  );

  // Per-rep detail records for summary screen (curl only).
  final List<CurlRepRecord> _curlRepRecords = [];

  // Completion channel — widget pushes SummaryScreen on emission.
  final StreamController<WorkoutCompletedEvent> _completionCtrl =
      StreamController.broadcast();

  // Per-error landmark highlight indices (curl only).
  static const Map<FormError, List<int>> _errorLandmarks = {
    FormError.torsoSwing: [LM.leftShoulder, LM.rightShoulder],
    FormError.elbowDrift: [LM.leftElbow, LM.rightElbow],
    FormError.shortRomStart: [LM.leftShoulder, LM.rightShoulder],
    FormError.shortRomPeak: [LM.leftWrist, LM.rightWrist],
    FormError.asymmetryLeftLag: [LM.leftElbow, LM.leftWrist],
    FormError.asymmetryRightLag: [LM.rightElbow, LM.rightWrist],
  };

  WorkoutViewModel({
    required this.exercise,
    required ProfileRepository profileRepository,
    this.forceCalibration = false,
    CameraService? camera,
    PoseService? pose,
    TtsService? tts,
  }) : _camera = camera ?? CameraService(),
       _pose = pose ?? MlKitPoseService(),
       _tts = tts ?? TtsService(),
       _profileRepository = profileRepository {
    _repCounter = RepCounter(
      exercise: exercise,
      curlThresholdsProvider: _resolveThresholds,
      onCurlRepCommit: _handleCurlRepCommit,
    );
  }

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
  int get calibrationReps => _calibrationReps;
  int get calibrationSecondsRemaining => _calibrationSecondsRemaining;
  String? get calibrationError => _calibrationError;
  double? get calibrationCurrentAngle => _calibrationCurrentAngle;
  CalibrationSummary? get calibrationSummary => _calibrationSummary;
  CameraService get camera => _camera;
  CurlRomProfile? get profile => _profile;
  Stream<WorkoutCompletedEvent> get completionEvents => _completionCtrl.stream;

  // ── Init ───────────────────────────────────────────────
  Future<void> init() async {
    try {
      await _pose.init();
      await _camera.init();
      await _tts.init();
      // Load profile first so the FSM provider sees correct buckets even
      // for the very first rep (no race with the camera stream).
      if (exercise == ExerciseType.bicepsCurl) {
        _profile = await _profileRepository.loadCurl() ?? CurlRomProfile();
        // Personal calibration is opt-in only — Settings → Recalibrate sets
        // `forceCalibration`. We never launch it automatically.
        if (forceCalibration) {
          _enterCalibration();
        }
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

  void _handleCurlRepCommit({
    required ProfileSide side,
    required CurlCameraView view,
    required double minAngle,
    required double maxAngle,
  }) {
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

    TelemetryLog.instance.log(
      'profile.update',
      'side=${side.name} view=${view.name} result=${result.name} '
          'samples=${bucket.sampleCount} '
          'min=${bucket.observedMinAngle.toStringAsFixed(1)} '
          'max=${bucket.observedMaxAngle.toStringAsFixed(1)}',
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
    if (exercise != ExerciseType.bicepsCurl) return;
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
      final result = await _pose.processCameraImage(
        image,
        _camera.sensorRotation,
      );

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
    if (exercise == ExerciseType.bicepsCurl) {
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
    if (exercise == ExerciseType.bicepsCurl) {
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
    if (exercise == ExerciseType.bicepsCurl) {
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

  // ── Form feedback coordinator ─────────────────────────
  void _onFormErrors(List<FormError> errors) {
    final now = DateTime.now();
    for (final err in errors) {
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

  static FormError _cooldownKeyFor(FormError err) => switch (err) {
    FormError.asymmetryLeftLag ||
    FormError.asymmetryRightLag => FormError.asymmetryLeftLag,
    _ => err,
  };

  static String _errorMessage(FormError err) => switch (err) {
    FormError.torsoSwing => "Don't swing",
    FormError.elbowDrift => 'Keep your elbow still',
    FormError.shortRomStart => 'Start from full extension',
    FormError.shortRomPeak => 'Curl all the way up',
    FormError.squatDepth => 'Go deeper',
    FormError.trunkTibia => 'Keep your chest up',
    FormError.hipSag => 'Keep your body straight',
    FormError.pushUpShortRom => 'Go lower',
    FormError.eccentricTooFast => 'Lower slowly',
    FormError.concentricTooFast => 'Control the lift',
    FormError.tempoInconsistent => 'Keep steady tempo',
    FormError.asymmetryLeftLag => 'Left arm is lagging',
    FormError.asymmetryRightLag => 'Right arm is lagging',
    FormError.fatigue => "You're slowing down, stay strong",
  };

  void _triggerHighlight(FormError err) {
    final landmarks = _errorLandmarks[err];
    if (landmarks == null) return;
    _highlightTimer?.cancel();
    _errorHighlight = {for (final idx in landmarks) idx: Colors.redAccent};
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
    _completionCtrl.add(
      WorkoutCompletedEvent(
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
      ),
    );
  }

  // ── Dispose ───────────────────────────────────────────
  @override
  void dispose() {
    _countdownTimer?.cancel();
    _highlightTimer?.cancel();
    _uncalibratedNoticeTimer?.cancel();
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
