import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../core/constants.dart';
import '../core/types.dart';
import '../engine/landmark_smoother.dart';
import '../engine/rep_counter.dart';
import '../models/pose_landmark.dart';
import '../services/camera_service.dart';
import '../services/pose/mlkit_pose_service.dart';
import '../services/pose/pose_service.dart';
import '../widgets/rep_counter_display.dart';
import '../widgets/skeleton_painter.dart';

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
  final LandmarkSmoother _smoother = LandmarkSmoother();

  bool _isReady = false;
  bool _isProcessing = false;
  String? _error;

  // Setup check state.
  WorkoutPhase _phase = WorkoutPhase.setupCheck;
  int _setupOkFrames = 0;
  Map<int, Color> _landmarkColors = {};

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
    _repCounter = RepCounter();
    _init();
  }

  Future<void> _init() async {
    try {
      await _pose.init();
      await _camera.init();
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

      if (_phase == WorkoutPhase.setupCheck) {
        _updateSetupCheck(result, smoothed);
      } else {
        // Run rep counter on raw landmarks.
        final snapshot = _repCounter.update(result);
        if (mounted) {
          setState(() {
            _landmarks = smoothed;
            _snapshot = snapshot;
            _landmarkColors = {};
          });
        }
      }
    } catch (_) {
      // Silently drop bad frames — don't crash the stream.
    }
  }

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
            _phase = WorkoutPhase.active;
            _landmarks = smoothed;
            _landmarkColors = {};
          });
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

  @override
  void dispose() {
    _camera.dispose();
    _pose.dispose();
    super.dispose();
  }

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
              landmarkColors: _landmarkColors.isNotEmpty ? _landmarkColors : null,
            ),
            size: Size.infinite,
          ),

        // Setup check banner — visible until all required landmarks are confirmed.
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

        // Rep counter overlay — bottom left, only during active phase.
        if (_phase == WorkoutPhase.active)
          Positioned(
            left: 16,
            bottom: 32,
            child: RepCounterDisplay(
              reps: _snapshot.reps,
              sets: _snapshot.sets,
              state: _snapshot.state,
              elbowAngle: _snapshot.elbowAngle,
              activeErrors: _snapshot.formErrors,
            ),
          ),
      ],
    );
  }
}
