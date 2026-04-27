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
  ///
  /// [requiredLandmarks] are ML Kit landmark indices the active exercise
  /// depends on (see [ExerciseRequirements]). When provided, the
  /// implementation MUST return an empty [PoseResult] (with [inferenceTime]
  /// preserved for telemetry honesty) if any required landmark is missing
  /// or below [kPoseGateMinConfidence]. This is the first-line filter
  /// against partial detections that would otherwise feed the engine half
  /// a body and produce duplicated/garbage extremes.
  Future<PoseResult> processCameraImage(
    CameraImage image,
    int sensorRotation, {
    List<int>? requiredLandmarks,
    List<int>? requiredLandmarksAlt,
    double? confidenceFloor,
    Set<int>? bestEffortLandmarks,
  });

  /// Fallback: Run inference on an NV21 camera frame (Android).
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
    // Default: not implemented
    return PoseResult(landmarks: [], inferenceTime: Duration.zero);
  }

  /// Whether the most recent frame had any required landmark within 5%
  /// of an image edge. Used by the host to surface camera-framing hints
  /// when the user is too close or too tight on the camera. Resets to
  /// false on every successful frame; latches true while gate failures
  /// continue. Defaults to false; non-MLKit implementations may leave
  /// this as false.
  bool get lastFrameNearEdge => false;

  /// Release resources.
  void dispose();
}
