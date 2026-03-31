import 'dart:typed_data';
import '../../models/pose_result.dart';

/// Abstract interface for any pose estimation backend.
/// Today: ML Kit. Tomorrow: swap in anything else without touching the rest.
abstract class PoseService {
  /// Human-readable name (for debug UI).
  String get name;

  /// Initialise the underlying model.
  Future<void> init();

  /// Run inference on an NV21 camera frame.
  Future<PoseResult> processNv21(
    Uint8List bytes,
    int width,
    int height,
    int sensorRotation,
  );

  /// Release resources.
  void dispose();
}
