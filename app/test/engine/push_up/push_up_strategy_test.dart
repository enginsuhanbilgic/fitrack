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
import 'package:fitrack/engine/push_up/push_up_rom_profile.dart';
import 'package:fitrack/engine/push_up/push_up_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a neutral synthetic pose — all confidence 0.9, landmarks at
/// plausible positions. The push-up FSM is angle-driven; the pose is only
/// used by the form analyzer's hip-sag evaluation, which tolerates
/// imperfect geometry.
PoseResult buildPose({bool sagging = false}) {
  PoseLandmark lm(int t, double x, double y, {double confidence = 0.9}) =>
      PoseLandmark(type: t, x: x, y: y, confidence: confidence);

  final leftShoulder = sagging
      ? lm(LM.leftShoulder, 0.20, 0.50)
      : lm(LM.leftShoulder, 0.45, 0.30);
  final rightShoulder = sagging
      ? lm(LM.rightShoulder, 0.20, 0.50)
      : lm(LM.rightShoulder, 0.55, 0.30);
  final leftHip = sagging
      ? lm(LM.leftHip, 0.55, 0.85)
      : lm(LM.leftHip, 0.46, 0.70);
  final rightHip = sagging
      ? lm(LM.rightHip, 0.55, 0.85)
      : lm(LM.rightHip, 0.54, 0.70);
  final leftAnkle = sagging
      ? lm(LM.leftAnkle, 0.90, 0.50)
      : lm(LM.leftAnkle, 0.46, 0.95);
  final rightAnkle = sagging
      ? lm(LM.rightAnkle, 0.90, 0.50)
      : lm(LM.rightAnkle, 0.54, 0.95);

  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      leftShoulder,
      rightShoulder,
      lm(LM.leftElbow, 0.42, 0.50),
      lm(LM.rightElbow, 0.58, 0.50),
      lm(LM.leftWrist, 0.40, 0.65),
      lm(LM.rightWrist, 0.60, 0.65),
      leftHip,
      rightHip,
      lm(LM.leftKnee, 0.46, 0.85),
      lm(LM.rightKnee, 0.54, 0.85),
      leftAnkle,
      rightAnkle,
    ],
  );
}

StrategyFrameOutput tickAt({
  required PushUpStrategy strategy,
  required RepState state,
  required double angle,
  PoseResult? pose,
}) {
  return strategy.tick(
    StrategyFrameInput(
      pose: pose ?? buildPose(),
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

    test(
      'DESCENDING commits shallow rep when attempt returns to extension',
      () {
        final strategy = PushUpStrategy();

        tickAt(strategy: strategy, state: RepState.idle, angle: 150);
        tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: kPushUpShallowRepMaxAngle,
        );
        final out = tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: kPushUpEndAngle,
        );

        expect(out.nextState, RepState.idle);
        expect(out.repCommitted, isTrue);
        expect(out.formErrors, contains(FormError.pushUpShortRom));
        expect(strategy.lastRepQuality, lessThan(1.0));
      },
    );

    test(
      'DESCENDING ignores tiny dip that never reaches shallow threshold',
      () {
        final strategy = PushUpStrategy();

        tickAt(strategy: strategy, state: RepState.idle, angle: 150);
        tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: kPushUpShallowRepMaxAngle + 10,
        );
        final out = tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: kPushUpEndAngle,
        );

        expect(out.nextState, RepState.idle);
        expect(out.repCommitted, isFalse);
        expect(out.formErrors, isEmpty);
      },
    );

    test('uses personalized thresholds from push-up calibration', () {
      const thresholds = PushUpRomThresholds(
        startAngle: 150,
        bottomAngle: 105,
        shallowRepMaxAngle: 125,
        endAngle: 150,
      );
      final strategy = PushUpStrategy(thresholds: thresholds);

      var out = tickAt(strategy: strategy, state: RepState.idle, angle: 155);
      expect(out.nextState, RepState.idle);

      out = tickAt(strategy: strategy, state: RepState.idle, angle: 145);
      expect(out.nextState, RepState.descending);

      out = tickAt(strategy: strategy, state: RepState.descending, angle: 102);
      expect(out.nextState, RepState.bottom);
    });

    test('restricted calibrated ROM still lets a real rep commit', () {
      final thresholds = PushUpRomProfile.calibrated(
        topAngle: 150,
        bottomAngle: 130,
      ).thresholds;
      final strategy = PushUpStrategy(thresholds: thresholds);

      tickAt(
        strategy: strategy,
        state: RepState.idle,
        angle: thresholds.startAngle - 1,
      );
      tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: thresholds.bottomAngle - 1,
      );
      tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: thresholds.bottomAngle + 1,
      );
      final out = tickAt(
        strategy: strategy,
        state: RepState.ascending,
        angle: thresholds.endAngle + 1,
      );

      expect(out.repCommitted, isTrue);
      expect(out.nextState, RepState.idle);
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
      expect(strategy.lastRepQuality, 1.0);
    });

    test(
      'sagging body line still commits rep with hipSag and lower quality',
      () {
        final strategy = PushUpStrategy();
        final sagPose = buildPose(sagging: true);

        tickAt(
          strategy: strategy,
          state: RepState.idle,
          angle: 150,
          pose: sagPose,
        );
        tickAt(
          strategy: strategy,
          state: RepState.descending,
          angle: 85,
          pose: sagPose,
        );
        tickAt(
          strategy: strategy,
          state: RepState.bottom,
          angle: 95,
          pose: sagPose,
        );
        final out = tickAt(
          strategy: strategy,
          state: RepState.ascending,
          angle: 165,
          pose: sagPose,
        );

        expect(out.repCommitted, isTrue);
        expect(out.formErrors, contains(FormError.hipSag));
        expect(strategy.lastRepQuality, lessThan(1.0));
        expect(
          strategy.lastBodyLineDeviationDeg,
          greaterThan(kHipSagDeviation),
        );
      },
    );

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

    test('primary angle uses the visible side instead of averaging sides', () {
      PoseLandmark lm(int type, double x, double y, double confidence) =>
          PoseLandmark(type: type, x: x, y: y, confidence: confidence);
      final pose = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: [
          lm(LM.leftShoulder, 0.45, 0.30, 0.1),
          lm(LM.leftElbow, 0.42, 0.50, 0.1),
          lm(LM.leftWrist, 0.40, 0.65, 0.1),
          lm(LM.rightShoulder, 0.60, 0.30, 0.9),
          lm(LM.rightElbow, 0.60, 0.50, 0.9),
          lm(LM.rightWrist, 0.80, 0.50, 0.9),
        ],
      );

      expect(PushUpStrategy().computePrimaryAngle(pose), closeTo(90, 0.01));
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
