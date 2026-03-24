import 'dart:typed_data';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';

/// Abstract contract for all pose estimation model implementations.
/// Each model converts raw bytes internally to its required format.
abstract class PoseEstimatorService {
  String get name;
  int get keypointCount;

  Future<void> initialize();

  /// The current region of interest (normalized [left, top, width, height]).
  /// If null, the full frame is used.
  List<double>? get currentRoi => null;

  /// Update the ROI based on the last result for "Smart Cropping" tracking.
  void updateRoi(PoseResult lastResult) {}

  /// Maps coordinates from the current ROI back to the original full-frame normalized space.
  List<PoseLandmark> mapToFullFrame(List<PoseLandmark> landmarks) {
    final roi = currentRoi;
    if (roi == null) return landmarks;

    final double l = roi[0], t = roi[1], w = roi[2], h = roi[3];
    return landmarks.map((lm) => PoseLandmark(
      type: lm.type,
      x: l + (lm.x * w),
      y: t + (lm.y * h),
      confidence: lm.confidence,
    )).toList();
  }

  /// Process a frame and return detected pose landmarks.
  /// [rgbBytes]: flat RGB bytes (length = width * height * 3).
  /// [width], [height]: the dimensions of the provided [rgbBytes] buffer.
  Future<PoseResult> processFrame(Uint8List rgbBytes, int width, int height);

  /// Process directly from NV21 bytes (used by ML Kit for zero-copy camera path).
  Future<PoseResult> processNv21Frame(
    Uint8List nv21Bytes, int width, int height, int rotation,
  ) {
    return processFrame(nv21Bytes, width, height);
  }

  void dispose();
}

