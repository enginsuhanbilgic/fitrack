import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;

import '../../core/platform_config.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import 'pose_service.dart';

/// ML Kit Pose (base / stream mode) — the benchmark winner at 22 FPS.
class MlKitPoseService extends PoseService {
  late mlkit.PoseDetector _detector;

  @override
  String get name => 'ML Kit Pose';

  @override
  Future<void> init() async {
    try {
      debugPrint(
        'DEBUG [ML Kit]: Initializing PoseDetector with base model, stream mode',
      );
      _detector = mlkit.PoseDetector(
        options: mlkit.PoseDetectorOptions(
          model: mlkit.PoseDetectionModel.base,
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
    int sensorRotation,
  ) async {
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

      return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
    } catch (e) {
      return PoseResult(landmarks: [], inferenceTime: Duration.zero);
    }
  }

  @override
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation,
  ) async {
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
