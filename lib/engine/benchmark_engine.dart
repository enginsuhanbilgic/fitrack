import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';
import '../models/benchmark_stats.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import '../screens/home_screen.dart';
import '../services/pose_estimator_service.dart';

class BenchmarkEngine {
  final PoseEstimatorService service;
  final ExerciseType exerciseType;
  
  // Performance Buffers
  final Queue<double> _latencyWindow = Queue<double>();
  final Queue<int> _frameTimestamps = Queue<int>();
  static const int _latencyWindowSize = 10;
  static const int _fpsWindowMs = 1000;

  // Stability
  final Map<int, Point<double>> _prevLandmarks = {};

  // Exercise Logic
  int _repCount = 0;
  ExerciseStage _stage = ExerciseStage.unknown;
  final List<double> _angleSmoothingBuffer = [];
  static const int _smoothingWindow = 3;

  // Thresholds
  static const double _curlUpThreshold = 65.0;
  static const double _curlDownThreshold = 145.0;

  BenchmarkEngine(this.service, this.exerciseType);

  /// Run inference and compute benchmark metrics.
  Future<(PoseResult, BenchmarkStats)> runInference(
    Uint8List rgbBytes, int width, int height,
  ) async {
    final sw = Stopwatch()..start();
    final result = await service.processFrame(rgbBytes, width, height);
    sw.stop();

    return _computeStats(result, sw.elapsedMicroseconds / 1000.0);
  }

  /// Run inference using NV21 bytes (ML Kit fast path).
  Future<(PoseResult, BenchmarkStats)> runNv21Inference(
    Uint8List nv21Bytes, int width, int height, int rotation,
  ) async {
    final sw = Stopwatch()..start();
    final result = await service.processNv21Frame(nv21Bytes, width, height, rotation);
    sw.stop();

    return _computeStats(result, sw.elapsedMicroseconds / 1000.0);
  }

  (PoseResult, BenchmarkStats) _computeStats(PoseResult result, double latencyMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    
    // 1. Rolling & Avg Latency
    _latencyWindow.addLast(latencyMs);
    if (_latencyWindow.length > _latencyWindowSize) _latencyWindow.removeFirst();
    final avgLatency = _latencyWindow.reduce((a, b) => a + b) / _latencyWindow.length;

    // 2. Rolling FPS (1s window)
    _frameTimestamps.addLast(now);
    while (_frameTimestamps.isNotEmpty && (now - _frameTimestamps.first) > _fpsWindowMs) {
      _frameTimestamps.removeFirst();
    }
    final double rollingFps = _frameTimestamps.length > 1 
        ? (_frameTimestamps.length - 1) * 1000.0 / (now - _frameTimestamps.first)
        : 0.0;

    // 3. Overall Average FPS (placeholder, usually computed from session total)
    final double fps = avgLatency > 0 ? 1000.0 / avgLatency : 0.0;

    // 4. Landmark stability: average jitter
    double jitter = 0;
    int count = 0;
    for (final lm in result.landmarks) {
      final prev = _prevLandmarks[lm.type];
      if (prev != null) {
        jitter += sqrt(pow(lm.x - prev.x, 2) + pow(lm.y - prev.y, 2));
        count++;
      }
      _prevLandmarks[lm.type] = Point(lm.x, lm.y);
    }
    final double stability = count > 0 ? jitter / count : 0.0;

    // 5. Exercise Analysis
    final double? jointAngle = _calculateElbowAngle(result.landmarks);
    if (jointAngle != null) {
      _dispatchRepLogic(jointAngle);
    }

    return (result, BenchmarkStats(
        avgFps: fps,
        rollingFps: rollingFps,
        latencyMs: latencyMs,
        stabilityJitter: stability,
        repCount: _repCount,
        stage: _stage,
        jointAngle: jointAngle,
      ),
    );
  }

  double? _calculateElbowAngle(List<PoseLandmark> landmarks) {
    if (service.keypointCount == 33) {
      // BlazePose (ML Kit): Left(11, 13, 15), Right(12, 14, 16)
      final double? leftAngle = _getAngle(landmarks, 11, 13, 15);
      final double? rightAngle = _getAngle(landmarks, 12, 14, 16);
      if (leftAngle != null && rightAngle != null) {
        return (leftAngle + rightAngle) / 2.0;
      }
      return leftAngle ?? rightAngle;
    } else {
      // COCO-17 (MoveNet, YOLO-Pose): Left(5, 7, 9), Right(6, 8, 10)
      final double? leftAngle = _getAngle(landmarks, 5, 7, 9);
      final double? rightAngle = _getAngle(landmarks, 6, 8, 10);
      if (leftAngle != null && rightAngle != null) {
        return (leftAngle + rightAngle) / 2.0;
      }
      return leftAngle ?? rightAngle;
    }
  }

  double? _getAngle(List<PoseLandmark> landmarks, int sIdx, int eIdx, int wIdx) {
    try {
      final s = landmarks.firstWhere((l) => l.type == sIdx && l.confidence > 0.3);
      final e = landmarks.firstWhere((l) => l.type == eIdx && l.confidence > 0.3);
      final w = landmarks.firstWhere((l) => l.type == wIdx && l.confidence > 0.3);

      final radians = atan2(w.y - e.y, w.x - e.x) - atan2(s.y - e.y, s.x - e.x);
      double angle = radians.abs() * 180.0 / pi;
      if (angle > 180.0) angle = 360 - angle;
      return angle;
    } catch (_) {
      return null;
    }
  }

  void _dispatchRepLogic(double angle) {
    switch (exerciseType) {
      case ExerciseType.bicepCurl:
        _processBicepCurl(angle);
    }
  }

  void _processBicepCurl(double angle) {
    // Smooth angle
    _angleSmoothingBuffer.add(angle);
    if (_angleSmoothingBuffer.length > _smoothingWindow) _angleSmoothingBuffer.removeAt(0);
    final smoothAngle = _angleSmoothingBuffer.reduce((a, b) => a + b) / _angleSmoothingBuffer.length;

    // State Machine
    if (smoothAngle < _curlUpThreshold && _stage != ExerciseStage.up) {
      _stage = ExerciseStage.up;
      _repCount++;
    } else if (smoothAngle > _curlDownThreshold && _stage != ExerciseStage.down) {
      _stage = ExerciseStage.down;
    }
  }

  void reset() {
    _latencyWindow.clear();
    _frameTimestamps.clear();
    _prevLandmarks.clear();
    _repCount = 0;
    _stage = ExerciseStage.unknown;
    _angleSmoothingBuffer.clear();
  }
}

