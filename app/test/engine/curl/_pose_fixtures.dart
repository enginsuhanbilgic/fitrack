/// Synthetic pose fixtures for curl form-analyzer tests.
///
/// The analyzer only reads: shoulders (for torso length + swing),
/// elbows (for drift), hips (for torso length). Everything else is
/// zero-confidence so `.landmark()` returns null.
library;

import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

/// Build a synthetic pose with shoulders, elbows, wrists, and hips.
///
/// Coordinates are normalized ([0, 1]). Confidence defaults to 0.9 (above
/// `kMinLandmarkConfidence = 0.4`) so every landmark is usable.
PoseResult buildPose({
  double leftShoulderX = 0.45,
  double leftShoulderY = 0.30,
  double rightShoulderX = 0.55,
  double rightShoulderY = 0.30,
  double leftElbowX = 0.42,
  double leftElbowY = 0.50,
  double rightElbowX = 0.58,
  double rightElbowY = 0.50,
  double leftWristX = 0.42,
  double leftWristY = 0.65,
  double rightWristX = 0.58,
  double rightWristY = 0.65,
  double leftHipX = 0.46,
  double leftHipY = 0.70,
  double rightHipX = 0.54,
  double rightHipY = 0.70,
  double confidence = 0.9,
}) {
  PoseLandmark lm(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);

  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, leftShoulderX, leftShoulderY),
      lm(LM.rightShoulder, rightShoulderX, rightShoulderY),
      lm(LM.leftElbow, leftElbowX, leftElbowY),
      lm(LM.rightElbow, rightElbowX, rightElbowY),
      lm(LM.leftWrist, leftWristX, leftWristY),
      lm(LM.rightWrist, rightWristX, rightWristY),
      lm(LM.leftHip, leftHipX, leftHipY),
      lm(LM.rightHip, rightHipX, rightHipY),
    ],
  );
}

/// Shift every horizontal landmark by [dx] — useful for swing tests.
PoseResult shiftHorizontal(PoseResult src, double dx) {
  return PoseResult(
    inferenceTime: src.inferenceTime,
    landmarks: src.landmarks
        .map(
          (l) => PoseLandmark(
            type: l.type,
            x: l.x + dx,
            y: l.y,
            confidence: l.confidence,
          ),
        )
        .toList(),
  );
}

/// Shift only the given landmark types by [dx] — useful for isolated elbow drift.
PoseResult shiftLandmarks(PoseResult src, Set<int> types, double dx) {
  return PoseResult(
    inferenceTime: src.inferenceTime,
    landmarks: src.landmarks
        .map(
          (l) => PoseLandmark(
            type: l.type,
            x: types.contains(l.type) ? l.x + dx : l.x,
            y: l.y,
            confidence: l.confidence,
          ),
        )
        .toList(),
  );
}
