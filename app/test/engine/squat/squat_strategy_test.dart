/// Strategy-level tests for `SquatStrategy`.
///
/// Covers:
///   - FSM transitions (idle → descending → bottom → ascending → idle).
///   - Per-rep state resets between reps.
///   - Session-scoped adaptation lifecycle: [onNextSet] preserves session
///     state, [onReset] clears it.
///
/// NOTE: The current long-femur detector in `SquatStrategy` gates on
/// `_repMinAngles.every((a) => a > kSquatBottomAngle)` AND requires the rep
/// to commit, which requires reaching BOTTOM (smoothed < 90°). These two
/// predicates are mutually exclusive under the default threshold — detection
/// only fires if a future change relaxes the BOTTOM gate. Tests here verify
/// the lifecycle (survive nextSet, clear on reset) by driving
/// [effectiveBottomAngle] through the legitimate production path, not
/// through a synthetic hack.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/engine/squat/squat_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a synthetic pose with hips at a given Y coordinate. All landmarks
/// pass the confidence gate so the strategy's `_computeHipY` helper returns
/// a value. Knees/ankles/shoulders are placed at plausible vertical offsets
/// so `evaluate()` doesn't crash.
PoseResult buildPoseWithHipY(double hipY) {
  PoseLandmark lm(int t, double x, double y) =>
      PoseLandmark(type: t, x: x, y: y, confidence: 0.9);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftHip, 0.48, hipY),
      lm(LM.rightHip, 0.52, hipY),
      lm(LM.leftKnee, 0.48, hipY + 0.15),
      lm(LM.rightKnee, 0.52, hipY + 0.15),
      lm(LM.leftAnkle, 0.48, hipY + 0.30),
      lm(LM.rightAnkle, 0.52, hipY + 0.30),
      lm(LM.leftShoulder, 0.48, hipY - 0.30),
      lm(LM.rightShoulder, 0.52, hipY - 0.30),
    ],
  );
}

StrategyFrameOutput tickAt({
  required SquatStrategy strategy,
  required RepState state,
  required double angle,
  required double hipY,
}) {
  return strategy.tick(
    StrategyFrameInput(
      pose: buildPoseWithHipY(hipY),
      smoothedAngle: angle,
      now: DateTime.now(),
      state: state,
      repIndexInSet: 0,
    ),
  );
}

/// Drive one complete squat rep through the strategy. Caller chooses the
/// `minAngle` the rep dips to — the FSM only enters BOTTOM when
/// `minAngle < effectiveBottomAngle`. Returns the final frame output which
/// has `repCommitted == true`.
StrategyFrameOutput driveRep({
  required SquatStrategy strategy,
  required double minAngle,
}) {
  // IDLE → DESCENDING (angle < kSquatStartAngle = 160).
  var out = tickAt(
    strategy: strategy,
    state: RepState.idle,
    angle: 150,
    hipY: 0.50,
  );
  expect(out.nextState, RepState.descending);

  // DESCENDING → BOTTOM (angle < effectiveBottomAngle, default 90).
  out = tickAt(
    strategy: strategy,
    state: RepState.descending,
    angle: minAngle,
    hipY: 0.60,
  );
  expect(
    out.nextState,
    RepState.bottom,
    reason:
        'minAngle $minAngle must dip below effectiveBottomAngle '
        '${strategy.effectiveBottomAngle}',
  );

  // Establish a previous hipY so the next frame can detect rise.
  tickAt(
    strategy: strategy,
    state: RepState.bottom,
    angle: minAngle,
    hipY: 0.60,
  );
  // BOTTOM → ASCENDING: hip rises (Y decreases in screen coords).
  out = tickAt(
    strategy: strategy,
    state: RepState.bottom,
    angle: minAngle + 5,
    hipY: 0.55,
  );
  expect(out.nextState, RepState.ascending);

  // ASCENDING → IDLE when angle >= kSquatEndAngle = 160.
  out = tickAt(
    strategy: strategy,
    state: RepState.ascending,
    angle: 165,
    hipY: 0.50,
  );
  expect(out.nextState, RepState.idle);
  expect(out.repCommitted, isTrue);
  return out;
}

void main() {
  group('SquatStrategy — FSM transitions', () {
    test('full rep cycle commits exactly once', () {
      final strategy = SquatStrategy();
      final out = driveRep(strategy: strategy, minAngle: 85);
      expect(out.repCommitted, isTrue);
    });

    test('ascending without reaching endAngle does not commit', () {
      final strategy = SquatStrategy();

      var out = tickAt(
        strategy: strategy,
        state: RepState.idle,
        angle: 150,
        hipY: 0.50,
      );
      expect(out.nextState, RepState.descending);

      out = tickAt(
        strategy: strategy,
        state: RepState.ascending,
        angle: 155, // below endAngle (160)
        hipY: 0.50,
      );
      expect(out.repCommitted, isFalse);
      expect(out.nextState, RepState.ascending);
    });

    test('descending returns to idle when user stands back up', () {
      final strategy = SquatStrategy();

      var out = tickAt(
        strategy: strategy,
        state: RepState.idle,
        angle: 150,
        hipY: 0.50,
      );
      expect(out.nextState, RepState.descending);

      out = tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: 165, // above startAngle (160) before reaching bottom
        hipY: 0.50,
      );
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isFalse);
    });

    test('bottom phase waits for hip to rise before flipping to ascending', () {
      final strategy = SquatStrategy();

      // IDLE → DESCENDING → BOTTOM.
      tickAt(strategy: strategy, state: RepState.idle, angle: 150, hipY: 0.50);
      var out = tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: 85,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);

      // Hip STILL at bottom — no rise — should stay in BOTTOM.
      out = tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: 85,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);

      // Hip FALLS further (Y increases) — still not rising, stay in BOTTOM.
      out = tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: 85,
        hipY: 0.62,
      );
      expect(out.nextState, RepState.bottom);
    });
  });

  group('SquatStrategy — lifecycle of session-scoped state', () {
    test('effectiveBottomAngle defaults to kSquatBottomAngle', () {
      final strategy = SquatStrategy();
      expect(strategy.effectiveBottomAngle, kSquatBottomAngle);
    });

    test('deep reps do not trigger long-femur adaptation', () {
      final strategy = SquatStrategy();
      // Drive 5 deep reps — min angle well below kSquatBottomAngle.
      for (var i = 0; i < 5; i++) {
        driveRep(strategy: strategy, minAngle: 80);
      }
      expect(
        strategy.effectiveBottomAngle,
        kSquatBottomAngle,
        reason: 'deep reps do not classify as long-femur',
      );
    });

    test('onNextSet clears per-rep state but preserves session state', () {
      final strategy = SquatStrategy();

      // Drive a partial rep leaving per-rep state populated.
      tickAt(strategy: strategy, state: RepState.idle, angle: 150, hipY: 0.50);
      tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: 85,
        hipY: 0.60,
      );

      final before = strategy.effectiveBottomAngle;
      strategy.onNextSet();

      // After onNextSet, the next rep must start cleanly (no stale hipY
      // causing a spurious BOTTOM→ASCENDING flip). Drive a full rep end-to-end.
      final out = driveRep(strategy: strategy, minAngle: 82);
      expect(out.repCommitted, isTrue);
      expect(
        strategy.effectiveBottomAngle,
        before,
        reason: 'session-scoped state survives onNextSet',
      );
    });

    test('onReset restores fresh strategy state', () {
      final strategy = SquatStrategy();

      // Drive two reps to populate internal state.
      driveRep(strategy: strategy, minAngle: 80);
      driveRep(strategy: strategy, minAngle: 85);

      strategy.onReset();

      // Post-reset, the strategy behaves identically to a newly-constructed one.
      expect(strategy.effectiveBottomAngle, kSquatBottomAngle);

      // A fresh rep still commits.
      final out = driveRep(strategy: strategy, minAngle: 82);
      expect(out.repCommitted, isTrue);
    });
  });
}
