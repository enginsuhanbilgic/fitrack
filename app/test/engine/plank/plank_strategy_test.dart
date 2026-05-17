import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/engine/plank/plank_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

PoseResult plankPose({
  bool sagging = false,
  bool badArm = false,
}) {
  PoseLandmark lm(int type, double x, double y, {double confidence = 0.9}) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);

  final hipY = sagging ? 0.72 : 0.50;
  final elbowX = badArm ? 0.72 : 0.30;
  final wrist = badArm
      ? lm(LM.leftWrist, 0.88, 0.64)
      : lm(LM.leftWrist, 0.45, 0.65);

  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.30, 0.50),
      lm(LM.leftElbow, elbowX, 0.65),
      wrist,
      lm(LM.leftHip, 0.55, hipY),
      lm(LM.leftAnkle, 0.85, 0.50),
      lm(LM.rightShoulder, 0.30, 0.50, confidence: 0.1),
      lm(LM.rightElbow, 0.30, 0.65, confidence: 0.1),
      lm(LM.rightWrist, 0.45, 0.65, confidence: 0.1),
      lm(LM.rightHip, 0.55, hipY, confidence: 0.1),
      lm(LM.rightAnkle, 0.85, 0.50, confidence: 0.1),
    ],
  );
}

StrategyFrameOutput tick(
  PlankStrategy strategy, {
  required PoseResult pose,
  required DateTime now,
  RepState state = RepState.idle,
}) {
  return strategy.tick(
    StrategyFrameInput(
      pose: pose,
      smoothedAngle: strategy.computePrimaryAngle(pose) ?? 0,
      now: now,
      state: state,
      repIndexInSet: 0,
    ),
  );
}

void main() {
  group('PlankStrategy', () {
    test('exposes plank metadata and requirements', () {
      final strategy = PlankStrategy();
      expect(strategy.exercise, ExerciseType.plank);
      expect(
        strategy.requiredLandmarkIndices,
        ExerciseRequirements.forExercise(ExerciseType.plank).landmarkIndices,
      );
    });

    test('primary angle reads forearm plank elbow angle', () {
      expect(
        PlankStrategy().computePrimaryAngle(plankPose()),
        closeTo(90, 0.01),
      );
    });

    test('commits one clean hold second only after a full valid second', () {
      final strategy = PlankStrategy();
      final t0 = DateTime(2026);

      var out = tick(strategy, pose: plankPose(), now: t0);
      expect(out.repCommitted, isFalse);
      expect(out.nextState, RepState.idle);

      out = tick(
        strategy,
        pose: plankPose(),
        now: t0.add(const Duration(milliseconds: 900)),
        state: out.nextState,
      );
      expect(out.repCommitted, isFalse);

      out = tick(
        strategy,
        pose: plankPose(),
        now: t0.add(const Duration(seconds: 1)),
        state: out.nextState,
      );
      expect(out.repCommitted, isTrue);
      expect(strategy.lastSecondSample?.valid, isTrue);
      expect(strategy.lastSecondSample?.quality, 1.0);
    });

    test('body-line break does not advance hold and lowers score', () {
      final strategy = PlankStrategy();
      final out = tick(
        strategy,
        pose: plankPose(sagging: true),
        now: DateTime(2026),
      );

      expect(out.repCommitted, isFalse);
      expect(out.formErrors, contains(FormError.plankBodyLine));
      expect(strategy.lastSecondSample?.valid, isFalse);
      expect(strategy.lastSecondSample?.quality, lessThan(1.0));
    });

    test('bad elbow angle blocks hold countdown', () {
      final strategy = PlankStrategy();
      final out = tick(
        strategy,
        pose: plankPose(badArm: true),
        now: DateTime(2026),
      );

      expect(out.formErrors, contains(FormError.plankArmAngle));
      expect(out.repCommitted, isFalse);
    });

    test('constants keep a practical forearm-plank target window', () {
      expect(kPlankElbowMinAngle, lessThan(90));
      expect(kPlankElbowMaxAngle, greaterThan(90));
      expect(kPlankTargetHoldSeconds, greaterThan(0));
    });
  });
}
