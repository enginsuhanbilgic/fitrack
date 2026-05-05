/// Strategy-level tests for `PushUpStrategy`.
///
/// Covers the FSM transitions and rep-commit semantics:
///   idle → descending (angle < 160)
///   descending → bottom (angle < 90)
///   bottom → ascending (angle > 90)
///   ascending → idle (angle >= 160) with repCommitted = true.
///
/// Push-up has no session-scoped state — all tracking resets per rep.
/// [onNextSet] and [onReset] are identical (both call form analyzer reset).
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/engine/push_up/push_up_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a neutral synthetic pose — all confidence 0.9, landmarks at
/// plausible positions. The push-up FSM is angle-driven; the pose is only
/// used by the form analyzer's hip-sag evaluation, which tolerates
/// imperfect geometry.
PoseResult buildPose() {
  PoseLandmark lm(int t, double x, double y) =>
      PoseLandmark(type: t, x: x, y: y, confidence: 0.9);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.45, 0.30),
      lm(LM.rightShoulder, 0.55, 0.30),
      lm(LM.leftElbow, 0.42, 0.50),
      lm(LM.rightElbow, 0.58, 0.50),
      lm(LM.leftWrist, 0.40, 0.65),
      lm(LM.rightWrist, 0.60, 0.65),
      lm(LM.leftHip, 0.46, 0.70),
      lm(LM.rightHip, 0.54, 0.70),
      lm(LM.leftKnee, 0.46, 0.85),
      lm(LM.rightKnee, 0.54, 0.85),
      lm(LM.leftAnkle, 0.46, 0.95),
      lm(LM.rightAnkle, 0.54, 0.95),
    ],
  );
}

StrategyFrameOutput tickAt({
  required PushUpStrategy strategy,
  required RepState state,
  required double angle,
}) {
  return strategy.tick(
    StrategyFrameInput(
      pose: buildPose(),
      smoothedAngle: angle,
      now: DateTime.now(),
      state: state,
      repIndexInSet: 0,
    ),
  );
}

void main() {
  group('PushUpStrategy — FSM transitions', () {
    test('IDLE holds while angle stays above startAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(strategy: strategy, state: RepState.idle, angle: 170);
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isFalse);
    });

    test('IDLE → DESCENDING when angle drops below startAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(strategy: strategy, state: RepState.idle, angle: 155);
      expect(out.nextState, RepState.descending);
    });

    test('DESCENDING → BOTTOM when angle drops below bottomAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: 85,
      );
      expect(out.nextState, RepState.bottom);
    });

    test(
      'DESCENDING → IDLE when user stands back up before reaching bottom',
      () {
        final strategy = PushUpStrategy();
        final out = tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: 165, // back above startAngle without hitting bottom
        );
        expect(out.nextState, RepState.idle);
        expect(out.repCommitted, isFalse);
      },
    );

    test('BOTTOM → ASCENDING when angle rises above bottomAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: 95, // > kPushUpBottomAngle (90)
      );
      expect(out.nextState, RepState.ascending);
    });

    test('ASCENDING → IDLE with repCommitted when angle crosses endAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(
        strategy: strategy,
        state: RepState.ascending,
        angle: kPushUpEndAngle, // boundary: >= kPushUpEndAngle triggers commit
      );
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isTrue);
    });

    test('ASCENDING holds while angle stays below endAngle', () {
      final strategy = PushUpStrategy();
      final out = tickAt(
        strategy: strategy,
        state: RepState.ascending,
        angle: 155,
      );
      expect(out.nextState, RepState.ascending);
      expect(out.repCommitted, isFalse);
    });
  });

  group('PushUpStrategy — full rep cycle', () {
    test('end-to-end: one rep commits exactly once', () {
      final strategy = PushUpStrategy();

      var out = tickAt(strategy: strategy, state: RepState.idle, angle: 170);
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isFalse);

      out = tickAt(strategy: strategy, state: RepState.idle, angle: 150);
      expect(out.nextState, RepState.descending);
      expect(out.repCommitted, isFalse);

      out = tickAt(strategy: strategy, state: RepState.descending, angle: 85);
      expect(out.nextState, RepState.bottom);
      expect(out.repCommitted, isFalse);

      out = tickAt(strategy: strategy, state: RepState.bottom, angle: 95);
      expect(out.nextState, RepState.ascending);
      expect(out.repCommitted, isFalse);

      out = tickAt(strategy: strategy, state: RepState.ascending, angle: 165);
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isTrue);
    });

    test('three consecutive reps each commit once', () {
      final strategy = PushUpStrategy();
      var commits = 0;

      for (var i = 0; i < 3; i++) {
        tickAt(strategy: strategy, state: RepState.idle, angle: 150);
        tickAt(strategy: strategy, state: RepState.descending, angle: 85);
        tickAt(strategy: strategy, state: RepState.bottom, angle: 95);
        final out = tickAt(
          strategy: strategy,
          state: RepState.ascending,
          angle: 165,
        );
        if (out.repCommitted) commits++;
      }

      expect(commits, 3);
    });
  });

  group('PushUpStrategy — metadata', () {
    test('exposes pushUp exercise type', () {
      expect(PushUpStrategy().exercise, ExerciseType.pushUp);
    });

    test('required landmarks match ExerciseRequirements registry', () {
      final expected = ExerciseRequirements.forExercise(
        ExerciseType.pushUp,
      ).landmarkIndices;
      expect(PushUpStrategy().requiredLandmarkIndices, expected);
    });
  });

  group('PushUpStrategy — reset semantics', () {
    test('onReset and onNextSet do not throw', () {
      final strategy = PushUpStrategy();
      tickAt(strategy: strategy, state: RepState.idle, angle: 150);
      expect(strategy.onNextSet, returnsNormally);
      expect(strategy.onReset, returnsNormally);
    });

    test('onReset allows a fresh rep to commit', () {
      final strategy = PushUpStrategy();

      // Partial rep: into descending but not committed.
      tickAt(strategy: strategy, state: RepState.idle, angle: 150);
      tickAt(strategy: strategy, state: RepState.descending, angle: 85);

      strategy.onReset();

      // New rep from clean slate.
      tickAt(strategy: strategy, state: RepState.idle, angle: 150);
      tickAt(strategy: strategy, state: RepState.descending, angle: 85);
      tickAt(strategy: strategy, state: RepState.bottom, angle: 95);
      final out = tickAt(
        strategy: strategy,
        state: RepState.ascending,
        angle: 165,
      );

      expect(out.repCommitted, isTrue);
    });
  });
}
