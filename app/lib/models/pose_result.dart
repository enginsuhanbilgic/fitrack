import 'pose_landmark.dart';

/// The output of a single pose-estimation inference.
class PoseResult {
  final List<PoseLandmark> landmarks;
  final Duration inferenceTime;

  const PoseResult({
    required this.landmarks,
    required this.inferenceTime,
  });

  /// Convenience: get a landmark by ML Kit type index.
  /// Returns null if not found or below [minConfidence].
  PoseLandmark? landmark(int type, {double minConfidence = 0.0}) {
    try {
      final lm = landmarks.firstWhere((l) => l.type == type);
      return lm.confidence >= minConfidence ? lm : null;
    } catch (_) {
      return null;
    }
  }

  bool get isEmpty => landmarks.isEmpty;
}
