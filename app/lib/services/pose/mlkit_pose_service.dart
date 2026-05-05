import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;

import '../../core/constants.dart';
import '../../core/platform_config.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import '../telemetry_log.dart';
import 'pose_service.dart';

/// ML Kit Pose (accurate model, stream mode).
class MlKitPoseService extends PoseService {
  late mlkit.PoseDetector _detector;

  /// Last time we emitted a `pose.quality_warn` log entry. Throttle to
  /// 1/second so a noisy session doesn't fill the 500-entry telemetry
  /// ring buffer (every frame would be ~30 entries/second, blowing the
  /// buffer in ~17 seconds).
  DateTime? _lastQualityWarnAt;

  /// Tracks whether the most recent processed frame had any required
  /// landmark within 5% of an image edge. Read by [WorkoutViewModel] to
  /// surface camera-framing hints. Updated on every frame regardless of
  /// gate pass/fail.
  bool _lastFrameNearEdge = false;

  @override
  bool get lastFrameNearEdge => _lastFrameNearEdge;

  @override
  String get name => 'ML Kit Pose';

  @override
  Future<void> init() async {
    try {
      debugPrint(
        'DEBUG [ML Kit]: Initializing PoseDetector with accurate model, '
        'stream mode',
      );
      // `accurate` is ML Kit's higher-accuracy model — meaningfully better
      // than `base` at occluded extremities (wrist near shoulder at peak
      // curl flexion, where `base` was producing snap artifacts and
      // surfacing as min=3°-style readings in rep.extremes telemetry).
      // Inference cost is ~10–15 ms higher per frame; well within the
      // 66 ms (15 FPS) frame budget set by `kActiveFrameIntervalMs`.
      _detector = mlkit.PoseDetector(
        options: mlkit.PoseDetectorOptions(
          model: mlkit.PoseDetectionModel.accurate,
          mode: mlkit.PoseDetectionMode.stream,
        ),
      );
      debugPrint('DEBUG [ML Kit]: PoseDetector initialized successfully');
    } catch (e) {
      debugPrint('ERROR [ML Kit]: Failed to initialize: $e');
      rethrow;
    }
  }

  @override
  Future<PoseResult> processCameraImage(
    CameraImage image,
    int sensorRotation, {
    List<int>? requiredLandmarks,
    List<int>? requiredLandmarksAlt,
    double? confidenceFloor,
    Set<int>? bestEffortLandmarks,
  }) async {
    try {
      // On iOS, use yuv420 format (NV12). On Android, use nv21.
      final format = PlatformConfig.instance.mlkitInputFormat;

      final inputImage = mlkit.InputImage.fromBytes(
        bytes: image.planes.first.bytes,
        metadata: mlkit.InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: _rotation(sensorRotation),
          format: format,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );

      final sw = Stopwatch()..start();
      final poses = await _detector.processImage(inputImage);
      sw.stop();

      if (poses.isEmpty) {
        return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
      }

      // Multi-pose warning: ML Kit detected more than one person/figure.
      // We still pick `poses.first` (ML Kit orders by detection
      // confidence) but flag it for the diagnostics screen — wrong-subject
      // tracking is a known cause of erratic landmark behavior in rooms
      // with TVs, mirrors, or posters.
      if (poses.length > 1) {
        _maybeWarnQuality(
          'multi_pose count=${poses.length}',
          inferenceTime: sw.elapsed,
        );
      }

      final pose = poses.first;

      final landmarks = <PoseLandmark>[];
      for (final entry in pose.landmarks.entries) {
        final type = entry.key;
        final lm = entry.value;

        final typeIndex = type.index;
        if (typeIndex >= 0 && typeIndex <= 32) {
          landmarks.add(
            PoseLandmark(
              type: typeIndex,
              x: (lm.x / image.width).clamp(0.0, 1.0),
              y: (lm.y / image.height).clamp(0.0, 1.0),
              confidence: lm.likelihood,
            ),
          );
        }
      }

      // Required-landmark gate. When the active exercise specifies which
      // landmarks it needs, reject the entire frame if any of them is
      // missing or below `kPoseGateMinConfidence`. Returning an empty
      // PoseResult is preferable to a partial one — the engine's
      // averaging logic treats missing landmarks as "use the other side,"
      // which is correct for genuine occlusion but wrong when the model
      // simply didn't bother to localize the wrist this frame.
      //
      // Telemetry surfaces three signals on each warning:
      // - `ids` — which landmark indices failed
      // - `conf` — their confidence values, parallel to `ids`. Helps tell
      //   "model is uncertain" (low conf) from "model is sure they're
      //   somewhere weird" (high conf with a bad position) — the latter
      //   typically indicates landmark snapping at peak flexion.
      // - `nearedge` — true when ANY required landmark (failed or not)
      //   sits within 5% of an image edge. Catches framing problems
      //   without per-landmark coordinate dumps.
      if (requiredLandmarks != null && requiredLandmarks.isNotEmpty) {
        // Default the public getter to false; flipped below when any
        // required landmark falls in the edge band. Set BEFORE the early
        // return so the host sees the framing signal even on rejected
        // frames (which is exactly when it matters most).
        _lastFrameNearEdge = false;

        // Resolve effective thresholds. Caller-supplied `confidenceFloor`
        // (e.g., the relaxed side-view value) overrides the default.
        // Best-effort landmarks (typically wrists in side view) accept
        // half the floor — the angle-calc downstream will skip frames
        // missing those landmarks, but the gate doesn't reject them
        // outright. Lets the FSM see partial-arm frames whose shoulder
        // and elbow are stable.
        final floor = confidenceFloor ?? kPoseGateMinConfidence;
        final bestEffort = bestEffortLandmarks ?? const <int>{};

        // Evaluate the primary group AND optional alternate group. If an
        // alternate is provided, the frame passes when EITHER fully
        // satisfies. Without an alternate, primary must pass.
        final primary = _evaluateLandmarkGroup(
          landmarks,
          requiredLandmarks,
          floor: floor,
          bestEffort: bestEffort,
        );
        final alt =
            requiredLandmarksAlt != null && requiredLandmarksAlt.isNotEmpty
            ? _evaluateLandmarkGroup(
                landmarks,
                requiredLandmarksAlt,
                floor: floor,
                bestEffort: bestEffort,
              )
            : null;
        _lastFrameNearEdge = primary.nearEdge || (alt?.nearEdge ?? false);

        final primaryOk = primary.missing.isEmpty;
        final altOk = alt != null && alt.missing.isEmpty;
        if (!primaryOk && !altOk) {
          // Surface the GROUP that came closer (fewer missing) to keep the
          // warning informative when an alt is in play.
          final report =
              (alt != null && alt.missing.length < primary.missing.length)
              ? alt
              : primary;
          final confStr = report.missingConfs
              .map((c) => c.toStringAsFixed(2))
              .join(',');
          _maybeWarnQuality(
            'missing_landmarks ids=${report.missing.join(",")} '
            'conf=$confStr nearedge=${report.nearEdge}',
            inferenceTime: sw.elapsed,
          );
          return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
        }
      }

      return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
    } catch (e) {
      return PoseResult(landmarks: [], inferenceTime: Duration.zero);
    }
  }

  /// Evaluate a single landmark group against the latest detected
  /// landmarks. Returns the missing IDs (with parallel confidences) and a
  /// nearedge flag. Pure function; no side effects.
  ///
  /// `floor` — confidence threshold for non-best-effort landmarks.
  /// `bestEffort` — landmark IDs that pass the gate at half the floor
  /// (e.g., wrists in side view, where ML Kit struggles at peak flexion
  /// but the FSM tolerates occasional missing angle frames).
  _GroupEvaluation _evaluateLandmarkGroup(
    List<PoseLandmark> landmarks,
    List<int> required, {
    required double floor,
    required Set<int> bestEffort,
  }) {
    final missing = <int>[];
    final missingConfs = <double>[];
    var nearEdge = false;
    for (final id in required) {
      final lm = landmarks.firstWhere(
        (l) => l.type == id,
        orElse: () => const PoseLandmark(type: -1, x: 0, y: 0, confidence: 0),
      );
      final effectiveFloor = bestEffort.contains(id) ? floor * 0.5 : floor;
      if (lm.type == -1 || lm.confidence < effectiveFloor) {
        missing.add(id);
        missingConfs.add(lm.type == -1 ? 0.0 : lm.confidence);
      }
      if (lm.type != -1) {
        if (lm.x < 0.05 || lm.x > 0.95 || lm.y < 0.05 || lm.y > 0.95) {
          nearEdge = true;
        }
      }
    }
    return _GroupEvaluation(missing, missingConfs, nearEdge);
  }

  /// Throttled pose-quality warning. Fires at most once per second so a
  /// degraded session doesn't flood the 500-entry telemetry ring.
  void _maybeWarnQuality(String detail, {required Duration inferenceTime}) {
    final now = DateTime.now();
    final last = _lastQualityWarnAt;
    if (last != null && now.difference(last).inMilliseconds < 1000) {
      return;
    }
    _lastQualityWarnAt = now;
    TelemetryLog.instance.log(
      'pose.quality_warn',
      '$detail inference_ms=${inferenceTime.inMilliseconds}',
    );
  }

  @override
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation, {
    List<int>? requiredLandmarks,
    List<int>? requiredLandmarksAlt,
    double? confidenceFloor,
    Set<int>? bestEffortLandmarks,
  }) async {
    // On iOS, use processCameraImage instead
    // This method is kept for Android compatibility
    debugPrint(
      'ERROR [ML Kit]: processNv21 called on iOS - this won\'t work! Use processCameraImage',
    );
    return PoseResult(landmarks: [], inferenceTime: Duration.zero);
  }

  @override
  void dispose() => _detector.close();

  static mlkit.InputImageRotation _rotation(int degrees) {
    switch (degrees) {
      case 90:
        return mlkit.InputImageRotation.rotation90deg;
      case 180:
        return mlkit.InputImageRotation.rotation180deg;
      case 270:
        return mlkit.InputImageRotation.rotation270deg;
      default:
        return mlkit.InputImageRotation.rotation0deg;
    }
  }
}

/// Per-group evaluation result for the required-landmark gate. Carries
/// missing IDs (with parallel confidences) and a nearedge flag so the
/// caller can pick whichever group came closer to passing when reporting.
class _GroupEvaluation {
  final List<int> missing;
  final List<double> missingConfs;
  final bool nearEdge;
  const _GroupEvaluation(this.missing, this.missingConfs, this.nearEdge);
}
