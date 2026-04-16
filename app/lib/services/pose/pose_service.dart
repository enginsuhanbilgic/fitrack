import 'dart:typed_data';
import 'package:camera/camera.dart';
import '../../models/pose_result.dart';

/// Abstract interface for any pose estimation backend.
/// Today: ML Kit. Tomorrow: swap in anything else without touching the rest.
abstract class PoseService {
  /// Human-readable name (for debug UI).
  String get name;

  /// Initialise the underlying model.
  Future<void> init();

  /// Run inference on a CameraImage directly.
  /// This preserves the native format which is critical for ML Kit on iOS.
  Future<PoseResult> processCameraImage(
    CameraImage image,
    int sensorRotation,
  );

  /// Fallback: Run inference on an NV21 camera frame (Android).
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation,
  ) async {
    // Default: not implemented
    return PoseResult(landmarks: [], inferenceTime: Duration.zero);
  }

  /// Release resources.
  void dispose();
}
