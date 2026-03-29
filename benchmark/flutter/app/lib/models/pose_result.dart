import 'pose_landmark.dart';

class PoseResult {
  final List<PoseLandmark> landmarks;
  final Duration inferenceTime;

  const PoseResult({
    required this.landmarks,
    required this.inferenceTime,
  });

  factory PoseResult.empty() => const PoseResult(
        landmarks: [],
        inferenceTime: Duration.zero,
      );

  bool get isEmpty => landmarks.isEmpty;
  int get landmarkCount => landmarks.length;
}
