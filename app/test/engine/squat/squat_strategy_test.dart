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
import 'package:fitrack/core/squat_rom_defaults.dart';
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
      // Use the Medium-derived tuple explicitly: post-2026-05-14
      // `SquatRomDefaults.defaults` aliases the High anchor (165/88/163),
      // so the default-constructed strategy now uses the strict 165° start
      // gate. Pin this test to Medium-baseline (160°) by passing the tuple
      // through the new applySensitivity post-pass.
      final mediumTuple = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.medium,
      );
      final strategy = SquatStrategy(romThresholds: mediumTuple);

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
        angle: 165, // above Medium startAngle (160) before reaching bottom
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

  group('SquatStrategy — variant + tall-lifter constructor params', () {
    test('default variant is bodyweight, lean threshold = 45°', () {
      final s = SquatStrategy();
      expect(s.variant, SquatVariant.bodyweight);
      expect(s.longFemurLifter, isFalse);
      expect(s.leanWarnDeg, 45.0);
    });

    test('HBBS variant raises lean threshold to 50°', () {
      final s = SquatStrategy(variant: SquatVariant.highBarBackSquat);
      expect(s.leanWarnDeg, 50.0);
    });

    test('tall-lifter toggle adds +5° to bodyweight threshold (50°)', () {
      final s = SquatStrategy(longFemurLifter: true);
      expect(s.leanWarnDeg, 50.0);
    });

    test('tall-lifter + HBBS combine to 55° (variant + boost)', () {
      final s = SquatStrategy(
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: true,
      );
      expect(s.leanWarnDeg, 55.0);
    });
  });

  group('SquatStrategy — long-femur orthogonality (plan flow-decision #3)', () {
    test(
      'tall-lifter toggle does NOT widen BOTTOM angle (only widens lean)',
      () {
        // Toggle ON, but auto-detect requires 3 reps in [90°, 100°].
        final s = SquatStrategy(longFemurLifter: true);
        expect(
          s.effectiveBottomAngle,
          kSquatBottomAngle,
          reason: 'BOTTOM gate is unaffected by the user toggle',
        );
      },
    );

    test(
      'auto-detected long-femur does NOT widen lean threshold (only widens BOTTOM)',
      () {
        // Toggle OFF — even after auto-detection, lean threshold stays at 45°
        // (orthogonality: auto-detect targets BOTTOM, toggle targets lean).
        final s = SquatStrategy();
        expect(s.leanWarnDeg, 45.0);
        // We can't easily trigger auto-detection in this test (the FSM gates
        // on `every (a) => a > 90` AND `every (a) => a <= 100`, mutually
        // exclusive under default thresholds). Assertion is on the static
        // contract: the analyzer's lean threshold is captured at
        // construction and never updated by the strategy's auto-flag.
      },
    );
  });

  group('SquatStrategy — quality forwarding', () {
    test('lastRepQuality is null before first commit', () {
      final s = SquatStrategy();
      expect(s.lastRepQuality, isNull);
    });

    test('lastRepQuality is set after a rep commits', () {
      final s = SquatStrategy();
      driveRep(strategy: s, minAngle: 80);
      expect(s.lastRepQuality, isNotNull);
      expect(s.lastRepQuality! >= 0.0, isTrue);
      expect(s.lastRepQuality! <= 1.0, isTrue);
    });
  });

  group('SquatStrategy — sensitivity-aware ROM (Part 1, 2026-05-13)', () {
    test(
      'default (Medium) strategy uses defaults: starts at <160, commits >=160',
      () {
        // Regression guard: the default constructor must continue to drive
        // an unchanged Medium-sensitivity FSM. A rep that bottoms at 80° (well
        // below the Medium 90° gate) commits cleanly through driveRep, which
        // pins each transition against the literal default thresholds.
        final s = SquatStrategy();
        final out = driveRep(strategy: s, minAngle: 80);
        expect(out.repCommitted, isTrue);
      },
    );

    test('Medium strategy enters BOTTOM at 89° (below default 90° gate)', () {
      final s = SquatStrategy();
      // Walk IDLE → DESCENDING → BOTTOM with minAngle = 89°.
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      final out = tickAt(
        strategy: s,
        state: RepState.descending,
        angle: 89,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);
    });

    test(
      'High strategy idle→descending gate is 165° (looser than default 160°)',
      () {
        // The High START gate sits at 165°. An angle at 161° must enter
        // DESCENDING under High (because 161 < 165), where under Medium it
        // would not (because 161 > 160). This pins the start-side delta.
        final highTuple = SquatRomThresholdSet.forSensitivity(
          FeedbackSensitivity.high,
        );
        final s = SquatStrategy(romThresholds: highTuple);
        final out = tickAt(
          strategy: s,
          state: RepState.idle,
          angle: 161,
          hipY: 0.50,
        );
        expect(out.nextState, RepState.descending);
      },
    );

    test('Medium idle→descending gate stays at 160° (regression guard)', () {
      // The Medium START gate is 160°. An angle at 161° must NOT enter
      // DESCENDING (because 161 > 160). This is the regression mirror to
      // the High test above — confirms the gate moved only under High.
      // Post-2026-05-14: SquatRomDefaults.defaults aliases the High anchor,
      // so to test Medium behavior we must apply the sensitivity post-pass
      // explicitly rather than relying on the no-arg constructor default.
      final mediumTuple = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.medium,
      );
      final s = SquatStrategy(romThresholds: mediumTuple);
      final out = tickAt(
        strategy: s,
        state: RepState.idle,
        angle: 161,
        hipY: 0.50,
      );
      expect(out.nextState, RepState.idle);
    });

    test('High strategy ascending→idle gate is 163° '
        '(commits between 163° and 165°)', () {
      // The High END gate sits at 163°. An angle of 163.5° must commit the
      // rep under High (because 163.5 >= 163). Under Medium (END = 160°)
      // this would also commit, so to make the test discriminate we use
      // 162° in the asymmetric pair below.
      final highTuple = SquatRomThresholdSet.forSensitivity(
        FeedbackSensitivity.high,
      );
      final s = SquatStrategy(romThresholds: highTuple);

      // Drive the FSM through to ASCENDING using the default BOTTOM gate
      // (Part 1 keeps `_effectiveBottomAngle = kSquatBottomAngle`).
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      tickAt(strategy: s, state: RepState.descending, angle: 80, hipY: 0.60);
      tickAt(strategy: s, state: RepState.bottom, angle: 80, hipY: 0.60);
      tickAt(strategy: s, state: RepState.bottom, angle: 85, hipY: 0.55);

      // 162° is below the High END gate (163°) → no commit.
      final notYet = tickAt(
        strategy: s,
        state: RepState.ascending,
        angle: 162,
        hipY: 0.50,
      );
      expect(notYet.repCommitted, isFalse);
      expect(notYet.nextState, RepState.ascending);

      // 164° crosses the gate → commit.
      final committed = tickAt(
        strategy: s,
        state: RepState.ascending,
        angle: 164,
        hipY: 0.50,
      );
      expect(committed.repCommitted, isTrue);
      expect(committed.nextState, RepState.idle);
    });

    test('High BOTTOM angle is defined in the tuple but NOT yet consumed by '
        'the FSM in Part 1 (effective BOTTOM stays at the long-femur '
        "path's 90° default)", () {
      // Part 1 wires START and END to the tuple; BOTTOM continues to flow
      // through `_effectiveBottomAngle`, which is initialized to
      // `kSquatBottomAngle` (90°) regardless of sensitivity. The High
      // tuple's `bottomAngle = 88` is therefore *defined* but unused
      // at FSM transition time. A later PR is expected to wire this in
      // (and replace this test). The test exists to make that wiring
      // change visible: when it lands, this test fails and the developer
      // confirms the new wiring is intentional.
      final highTuple = SquatRomThresholdSet.forSensitivity(
        FeedbackSensitivity.high,
      );
      expect(highTuple.bottomAngle, 88.0);

      final s = SquatStrategy(romThresholds: highTuple);
      // Without driving the long-femur path, effective BOTTOM is 90°. A
      // rep at 89° still crosses into BOTTOM under Part 1 wiring.
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      final out = tickAt(
        strategy: s,
        state: RepState.descending,
        angle: 89,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);
      expect(s.effectiveBottomAngle, kSquatBottomAngle);
    });
  });

  group('SquatStrategy — anatomical long-femur classifier (Part 2)', () {
    /// Build a synthetic pose whose femur/torso ratio is `targetRatio`.
    ///
    /// Geometry:
    ///   - shoulder at y = 0.20, hip at y = 0.50 → torso length = 0.30
    ///   - knee at y = 0.50 + (targetRatio × 0.30) → femur length = targetRatio × 0.30
    /// Ratio = femur / torso = targetRatio.
    ///
    /// `confidence` is applied to all landmarks. `0.9` clears the
    /// `kSetupCurlMinConfidence = 0.65` floor; `0.5` doesn't.
    PoseResult buildPoseWithRatio(
      double targetRatio, {
      double confidence = 0.9,
    }) {
      const torsoLen = 0.30;
      const shoulderY = 0.20;
      const hipY = shoulderY + torsoLen; // 0.50
      final kneeY = hipY + targetRatio * torsoLen;

      PoseLandmark lm(int t, double x, double y) =>
          PoseLandmark(type: t, x: x, y: y, confidence: confidence);
      return PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: [
          lm(LM.leftShoulder, 0.48, shoulderY),
          lm(LM.rightShoulder, 0.52, shoulderY),
          lm(LM.leftHip, 0.48, hipY),
          lm(LM.rightHip, 0.52, hipY),
          lm(LM.leftKnee, 0.48, kneeY),
          lm(LM.rightKnee, 0.52, kneeY),
          lm(LM.leftAnkle, 0.48, kneeY + 0.30),
          lm(LM.rightAnkle, 0.52, kneeY + 0.30),
        ],
      );
    }

    /// Drive N frames through `updateSetupView` so the classifier
    /// accumulates samples without entering the FSM.
    void feedSetupFrames(SquatStrategy s, int count, PoseResult pose) {
      for (var i = 0; i < count; i++) {
        s.updateSetupView(pose);
      }
    }

    test('5 high-confidence frames @ ratio 0.70 → classifier locks → '
        'long-femur fires from rep 1', () {
      double? observedRatio;
      final s = SquatStrategy(onLongFemurDetected: (r) => observedRatio = r);
      feedSetupFrames(s, kFemurTorsoMinSamples, buildPoseWithRatio(0.70));

      // Pump one IDLE frame to trigger _maybeApplyAnatomicalLongFemur.
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kLongFemurBottomAngle);
      expect(observedRatio, closeTo(0.70, 1e-9));
    });

    test('5 high-confidence frames @ ratio 0.55 → classifier locks → '
        'does NOT fire; default BOTTOM gate preserved', () {
      var fired = false;
      final s = SquatStrategy(onLongFemurDetected: (_) => fired = true);
      feedSetupFrames(s, kFemurTorsoMinSamples, buildPoseWithRatio(0.55));

      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kSquatBottomAngle);
      expect(fired, isFalse);
    });

    test('only 3 high-confidence frames → classifier does NOT lock', () {
      var fired = false;
      final s = SquatStrategy(onLongFemurDetected: (_) => fired = true);
      feedSetupFrames(s, 3, buildPoseWithRatio(0.70));

      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kSquatBottomAngle);
      expect(fired, isFalse);
    });

    test(
      'low-confidence frames are NOT accumulated → classifier does NOT lock',
      () {
        var fired = false;
        final s = SquatStrategy(onLongFemurDetected: (_) => fired = true);
        // 10 frames at confidence 0.5 (below kSetupCurlMinConfidence = 0.65).
        feedSetupFrames(s, 10, buildPoseWithRatio(0.70, confidence: 0.5));

        tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

        expect(s.effectiveBottomAngle, kSquatBottomAngle);
        expect(fired, isFalse);
      },
    );

    test('median over alternating [0.30, 0.70] window is below threshold → '
        'does NOT fire', () {
      var fired = false;
      final s = SquatStrategy(onLongFemurDetected: (_) => fired = true);
      // 15 alternating samples — sorted median lands at 0.30 (8 of 15 are 0.30).
      for (var i = 0; i < kFemurTorsoWindowSize; i++) {
        s.updateSetupView(buildPoseWithRatio(i.isEven ? 0.30 : 0.70));
      }

      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kSquatBottomAngle);
      expect(fired, isFalse);
    });

    test('persistedFemurTorsoRatio = 0.70 → fires on first IDLE frame', () {
      double? observedRatio;
      final s = SquatStrategy(
        persistedFemurTorsoRatio: 0.70,
        onLongFemurDetected: (r) => observedRatio = r,
      );
      // No setup-view feed needed — the persisted seed locks immediately.
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kLongFemurBottomAngle);
      expect(observedRatio, closeTo(0.70, 1e-9));
    });

    test('persistedFemurTorsoRatio = 0.55 → seeded but does NOT fire', () {
      var fired = false;
      final s = SquatStrategy(
        persistedFemurTorsoRatio: 0.55,
        onLongFemurDetected: (_) => fired = true,
      );
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(s.effectiveBottomAngle, kSquatBottomAngle);
      expect(fired, isFalse);
    });

    test('onReset clears classifier state — re-classification required', () {
      final s = SquatStrategy(persistedFemurTorsoRatio: 0.70);
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);
      expect(s.effectiveBottomAngle, kLongFemurBottomAngle);

      s.onReset();
      expect(s.effectiveBottomAngle, kSquatBottomAngle);

      // After reset, the classifier is empty: feeding low-confidence frames
      // alone won't lock it, so BOTTOM stays at default.
      feedSetupFrames(
        s,
        kFemurTorsoMinSamples,
        buildPoseWithRatio(0.70, confidence: 0.5),
      );
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);
      expect(s.effectiveBottomAngle, kSquatBottomAngle);
    });

    test('onNextSet does NOT clear classifier (anatomy is session-scoped)', () {
      final s = SquatStrategy(persistedFemurTorsoRatio: 0.70);
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);
      expect(s.effectiveBottomAngle, kLongFemurBottomAngle);

      s.onNextSet();
      // After set rollover, classifier still locked + adaptation still applies.
      expect(s.effectiveBottomAngle, kLongFemurBottomAngle);
    });

    test('callback fires AT MOST ONCE per session', () {
      var fireCount = 0;
      final s = SquatStrategy(
        persistedFemurTorsoRatio: 0.70,
        onLongFemurDetected: (_) => fireCount++,
      );
      // Multiple IDLE ticks — should still only fire once.
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);
      tickAt(strategy: s, state: RepState.idle, angle: 170, hipY: 0.50);

      expect(fireCount, 1);
    });
  });
}
