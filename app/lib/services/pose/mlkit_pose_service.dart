import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;
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
    _detector = mlkit.PoseDetector(
      options: mlkit.PoseDetectorOptions(
        model: mlkit.PoseDetectionModel.base,
        mode: mlkit.PoseDetectionMode.stream,
      ),
    );
  }

  @override
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation,
  ) async {
    final inputImage = mlkit.InputImage.fromBytes(
      bytes: bytes,
      metadata: mlkit.InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: _rotation(sensorRotation),
        format: mlkit.InputImageFormat.nv21,
        bytesPerRow: width,
      ),
    );

    final sw = Stopwatch()..start();
    final poses = await _detector.processImage(inputImage);
    sw.stop();

    if (poses.isEmpty) {
      return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
    }

    final pose = poses.first;

    // ML Kit returns coordinates in the rotated output space.
    final bool isRotated =
        sensorRotation == 90 || sensorRotation == 270;
    final double outW = isRotated ? height.toDouble() : width.toDouble();
    final double outH = isRotated ? width.toDouble() : height.toDouble();

    final landmarks = pose.landmarks.entries.map((e) {
      final lm = e.value;
      return PoseLandmark(
        type: lm.type.index,
        x: lm.x / outW,
        y: lm.y / outH,
        confidence: lm.likelihood,
      );
    }).toList();

    return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
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
