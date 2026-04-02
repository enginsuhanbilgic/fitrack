import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/types.dart';
import '../engine/landmark_smoother.dart';
import '../engine/rep_counter.dart';
import '../models/landmark_types.dart';
import '../models/pose_landmark.dart';
import '../services/camera_service.dart';
import '../services/pose/mlkit_pose_service.dart';
import '../services/pose/pose_service.dart';
import '../services/tts_service.dart';
import '../widgets/rep_counter_display.dart';
import '../widgets/skeleton_painter.dart';
import 'summary_screen.dart';

class WorkoutScreen extends StatefulWidget {
  final ExerciseType exercise;
  const WorkoutScreen({super.key, required this.exercise});

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen> {
  final CameraService _camera = CameraService();
  late final PoseService _pose;
  late final RepCounter _repCounter;
  late final TtsService _tts;
  final LandmarkSmoother _smoother = LandmarkSmoother();

  bool _isReady = false;
  bool _isProcessing = false;
  String? _error;

  // Phase state machine.
  WorkoutPhase _phase = WorkoutPhase.setupCheck;

  // SETUP_CHECK state.
  int _setupOkFrames = 0;
  Map<int, Color> _landmarkColors = {};

  // COUNTDOWN state.
  int _countdownValue = kCountdownSeconds;
  Timer? _countdownTimer;

  // ACTIVE state.
  DateTime? _absenceStart;
  DateTime? _activeStart;

  // Feedback coordinator (form errors → TTS cooldown per error type).
  final Map<FormError, DateTime> _lastFeedbackTime = {};

  // Visual highlight for curl form errors (landmark index → color).
  Map<int, Color> _errorHighlight = {};
  Timer? _highlightTimer;

  // Per-error landmark indices for visual highlight (curl only).
  static const Map<FormError, List<int>> _errorLandmarks = {
    FormError.torsoSwing: [LM.leftShoulder, LM.rightShoulder],
    FormError.elbowDrift: [LM.leftElbow, LM.rightElbow],
    FormError.shortRom:   [LM.leftWrist, LM.rightWrist],
  };

  // Mid-session occlusion (partial landmark loss within ACTIVE phase).
  DateTime? _occlusionStart;
  int _occlusionResumeFrames = 0;
  bool _isOccluded = false;
  DateTime? _lastOcclusionTts;

  // Per-frame display state.
  List<PoseLandmark> _landmarks = [];
  RepSnapshot _snapshot = const RepSnapshot(
    reps: 0,
    sets: 1,
    state: RepState.idle,
  );

  @override
  void initState() {
    super.initState();
    _pose = MlKitPoseService();
    _repCounter = RepCounter(exercise: widget.exercise);
    _tts = TtsService();
    _init();
  }

  Future<void> _init() async {
    try {
      await _pose.init();
      await _camera.init();
      await _tts.init();
      _camera.startStream(_onFrame);
      if (mounted) setState(() => _isReady = true);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onFrame(Uint8List nv21, int width, int height) {
    if (_isProcessing || !mounted) return;
    _isProcessing = true;

    _processFrame(nv21, width, height).whenComplete(() {
      _isProcessing = false;
    });
  }

  Future<void> _processFrame(Uint8List nv21, int width, int height) async {
    try {
      final result = await _pose.processNv21(
        nv21,
        width,
        height,
        _camera.sensorRotation,
      );

      if (result.isEmpty || !mounted) return;

      // Smooth + mirror for display only.
      final mirrored = result.landmarks.map((lm) => PoseLandmark(
        type: lm.type,
        x: _camera.isFrontCamera ? 1.0 - lm.x : lm.x,
        y: lm.y,
        confidence: lm.confidence,
      )).toList();
      final smoothed = _smoother.smooth(mirrored);

      switch (_phase) {
        case WorkoutPhase.setupCheck:
          _updateSetupCheck(result, smoothed);
        case WorkoutPhase.countdown:
          _updateCountdownFrame(result, smoothed);
        case WorkoutPhase.active:
          _updateActive(result, smoothed);
        case WorkoutPhase.completed:
          break; // session over — ignore incoming frames
      }
    } catch (_) {
      // Silently drop bad frames — don't crash the stream.
    }
  }

  // ── SETUP_CHECK ────────────────────────────────────────

  void _updateSetupCheck(dynamic result, List<PoseLandmark> smoothed) {
    final requirements = ExerciseRequirements.forExercise(widget.exercise);
    final colors = <int, Color>{};
    var allVisible = true;

    for (final idx in requirements.landmarkIndices) {
      final lm = result.landmark(idx, minConfidence: kMinLandmarkConfidence);
      if (lm != null) {
        colors[idx] = const Color(0xFF00E676); // green — visible
      } else {
        colors[idx] = Colors.redAccent; // red — not visible
        allVisible = false;
      }
    }

    if (allVisible) {
      _setupOkFrames++;
      if (_setupOkFrames >= kSetupCheckFrames) {
        if (mounted) {
          setState(() {
            _phase = WorkoutPhase.countdown;
            _landmarks = smoothed;
            _landmarkColors = {};
          });
          _startCountdown();
        }
        return;
      }
    } else {
      _setupOkFrames = 0;
    }

    if (mounted) {
      setState(() {
        _landmarks = smoothed;
        _landmarkColors = colors;
      });
    }
  }

  // ── COUNTDOWN ──────────────────────────────────────────

  void _startCountdown() {
    _countdownValue = kCountdownSeconds;
    _tts.speak('$_countdownValue');
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      _countdownValue--;
      if (_countdownValue > 0) {
        _tts.speak('$_countdownValue');
        setState(() {});
      } else {
        timer.cancel();
        _tts.speak('Go! Starting ${widget.exercise.label}');
        setState(() {
          _phase = WorkoutPhase.active;
          _activeStart = DateTime.now();
          _landmarkColors = {};
        });
      }
    });
  }

  void _updateCountdownFrame(dynamic result, List<PoseLandmark> smoothed) {
    final requirements = ExerciseRequirements.forExercise(widget.exercise);
    final allVisible = requirements.landmarkIndices.every(
      (idx) => result.landmark(idx, minConfidence: kMinLandmarkConfidence) != null,
    );

    if (!allVisible) {
      // User left frame mid-countdown — cancel and reset to setup check.
      _countdownTimer?.cancel();
      _tts.stop();
      if (mounted) {
        setState(() {
          _phase = WorkoutPhase.setupCheck;
          _setupOkFrames = 0;
          _countdownValue = kCountdownSeconds;
          _landmarks = smoothed;
        });
      }
    } else {
      if (mounted) setState(() => _landmarks = smoothed);
    }
  }

  // ── ACTIVE ─────────────────────────────────────────────

  void _updateActive(dynamic result, List<PoseLandmark> smoothed) {
    final requirements = ExerciseRequirements.forExercise(widget.exercise);
    final total = requirements.landmarkIndices.length;
    final visible = requirements.landmarkIndices
        .where((idx) => result.landmark(idx, minConfidence: kMinLandmarkConfidence) != null)
        .length;

    if (visible == total) {
      // ── All landmarks visible ──────────────────────────
      _absenceStart = null;
      _occlusionStart = null;

      if (_isOccluded) {
        // Counting recovery frames before resuming.
        _occlusionResumeFrames++;
        if (_occlusionResumeFrames >= kOcclusionResumeFrames) {
          setState(() => _isOccluded = false);
          _occlusionResumeFrames = 0;
        }
      }

      final snapshot = _repCounter.update(result);
      if (snapshot.formErrors.isNotEmpty) _onFormErrors(snapshot.formErrors);
      if (mounted) {
        setState(() {
          _landmarks = smoothed;
          _snapshot = snapshot;
        });
      }
    } else if (visible > 0) {
      // ── Partial occlusion — user still present ─────────
      _absenceStart = null;  // never auto-terminate during partial occlusion
      _occlusionResumeFrames = 0;
      _occlusionStart ??= DateTime.now();

      final occludedMs = DateTime.now().difference(_occlusionStart!).inMilliseconds;
      if (occludedMs >= kOcclusionPromptSec * 1000 && !_isOccluded) {
        setState(() => _isOccluded = true);
        if (_canSpeakOcclusionPrompt()) {
          _tts.speak('Move into frame — keep all joints visible');
          _lastOcclusionTts = DateTime.now();
        }
      }

      // FSM frozen — do not call _repCounter.update()
      if (mounted) setState(() => _landmarks = smoothed);
    } else {
      // ── Full absence — no landmarks at all ────────────
      _occlusionStart = null;
      _occlusionResumeFrames = 0;
      if (_isOccluded) setState(() => _isOccluded = false);

      _absenceStart ??= DateTime.now();
      final absentMs = DateTime.now().difference(_absenceStart!).inMilliseconds;
      if (absentMs >= kAbsenceTimeoutSec * 1000) {
        _triggerCompleted();
      }
    }
  }

  // ── Form Feedback Coordinator ──────────────────────────

  void _onFormErrors(List<FormError> errors) {
    final now = DateTime.now();
    for (final err in errors) {
      final last = _lastFeedbackTime[err];
      if (last != null && now.difference(last).inSeconds < kFeedbackCooldownSec) continue;
      _lastFeedbackTime[err] = now;
      _tts.speak(_errorMessage(err));
      _triggerHighlight(err);
      break; // one cue per update — list order defines priority
    }
  }

  String _errorMessage(FormError err) => switch (err) {
    FormError.torsoSwing     => "Don't swing",
    FormError.elbowDrift     => 'Keep your elbow still',
    FormError.shortRom       => 'Full range of motion',
    FormError.squatDepth     => 'Go deeper',
    FormError.trunkTibia     => 'Keep your chest up',
    FormError.hipSag         => 'Keep your body straight',
    FormError.pushUpShortRom => 'Go lower',
  };

  void _triggerHighlight(FormError err) {
    final landmarks = _errorLandmarks[err];
    if (landmarks == null) return; // squat/push-up — TTS only
    _highlightTimer?.cancel();
    setState(() {
      _errorHighlight = {for (final idx in landmarks) idx: Colors.redAccent};
    });
    _highlightTimer = Timer(
      Duration(milliseconds: kHighlightDurationMs),
      () { if (mounted) setState(() => _errorHighlight = {}); },
    );
  }

  bool _canSpeakOcclusionPrompt() {
    if (_lastOcclusionTts == null) return true;
    return DateTime.now().difference(_lastOcclusionTts!).inSeconds >= kFeedbackCooldownSec;
  }

  // ── COMPLETED ──────────────────────────────────────────

  void _triggerCompleted() {
    if (_phase == WorkoutPhase.completed) return; // guard against double-fire
    final duration = _activeStart != null
        ? DateTime.now().difference(_activeStart!)
        : Duration.zero;
    setState(() => _phase = WorkoutPhase.completed);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SummaryScreen(
        exercise: widget.exercise,
        totalReps: _snapshot.reps,
        totalSets: _snapshot.sets,
        sessionDuration: duration,
      ),
    ));
  }

  // ── Lifecycle ──────────────────────────────────────────

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _highlightTimer?.cancel();
    _tts.dispose();
    _camera.dispose();
    _pose.dispose();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.exercise.label),
        actions: [
          if (_phase == WorkoutPhase.active)
            IconButton(
              icon: const Icon(Icons.replay),
              tooltip: 'New set',
              onPressed: () {
                _repCounter.nextSet();
                setState(() {
                  _snapshot = RepSnapshot(
                    reps: 0,
                    sets: _snapshot.sets + 1,
                    state: RepState.idle,
                  );
                });
              },
            ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
        ),
      );
    }

    if (!_isReady) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF00E676)),
            SizedBox(height: 16),
            Text('Starting camera...',
                style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview.
        if (_camera.controller != null)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _camera.controller!.value.previewSize!.height,
                height: _camera.controller!.value.previewSize!.width,
                child: CameraPreview(_camera.controller!),
              ),
            ),
          ),

        // Skeleton overlay.
        if (_landmarks.isNotEmpty)
          CustomPaint(
            painter: SkeletonPainter(
              landmarks: _landmarks,
              mirror: false, // already mirrored above
              landmarkColors: () {
                final merged = {..._landmarkColors, ..._errorHighlight};
                return merged.isNotEmpty ? merged : null;
              }(),
            ),
            size: Size.infinite,
          ),

        // SETUP_CHECK banner.
        if (_phase == WorkoutPhase.setupCheck)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black87,
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
              child: Text(
                _setupOkFrames > 0
                    ? 'Almost there… ($_setupOkFrames / $kSetupCheckFrames)'
                    : 'Step back until your full body is visible',
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // COUNTDOWN overlay — bold number centered on screen.
        if (_phase == WorkoutPhase.countdown)
          Center(
            child: Text(
              '$_countdownValue',
              style: const TextStyle(
                fontSize: 160,
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),

        // ACTIVE — mid-session occlusion banner (orange, top).
        if (_phase == WorkoutPhase.active && _isOccluded)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.orange.withValues(alpha: 0.85),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
              child: const Text(
                'Move into frame — keep all joints visible',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        // ACTIVE — rep counter overlay bottom left.
        if (_phase == WorkoutPhase.active)
          Positioned(
            left: 16,
            bottom: 32,
            child: RepCounterDisplay(
              reps: _snapshot.reps,
              sets: _snapshot.sets,
              state: _snapshot.state,
              jointAngle: _snapshot.jointAngle,
              activeErrors: _snapshot.formErrors,
            ),
          ),
      ],
    );
  }
}
