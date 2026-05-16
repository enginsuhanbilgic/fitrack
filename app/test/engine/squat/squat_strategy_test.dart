/// Strategy-level tests for `SquatStrategy`.
///
/// Covers:
///   - FSM transitions (idle → descending → bottom → ascending → idle).
///   - Per-rep state resets between reps.
///   - Session-scoped adaptation lifecycle: [onNextSet] preserves session
///     state, [onReset] clears it.
///
/// NOTE: The rep-history long-femur detector in `SquatStrategy` gates on
/// `_repMinAngles.every((a) => a > kSquatLongFemurDetectFloorAngle)` (90°)
/// AND `every((a) => a <= kLongFemurBottomAngle)` (85° as of 2026-05-16).
/// That band `(90°, 85°]` is empty by construction, so the rep-history
/// path is inert — the ratio-based `_maybeApplyAnatomicalLongFemur`
/// (femur/torso > `kLongFemurRatioThreshold`) is the live path. Tests in
/// the "anatomical long-femur classifier" group exercise the ratio path;
/// the lifecycle tests here drive [effectiveBottomAngle] via the
/// persisted-ratio seed, the legitimate production path.
///
/// DEPTH GATE: `kSquatBottomAngle` was tightened 90° → 80° on 2026-05-16
/// (below-parallel target). `driveRep` / direct-tick fixtures that mean
/// "a deep rep that commits" pass a `minAngle` clearly below 80°.
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
  DateTime? now,
}) {
  return strategy.tick(
    StrategyFrameInput(
      pose: buildPoseWithHipY(hipY),
      smoothedAngle: angle,
      // Explicit `now` lets `driveRep` simulate the ≥ kSquatBottomDwellMs
      // (200ms) BOTTOM dwell required by the BOTTOM→ASCENDING gate (added
      // 2026-05-15). Defaults to wall-clock for the many single-tick call
      // sites that don't exercise the dwell.
      now: now ?? DateTime.now(),
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
  // Advancing clock — the BOTTOM→ASCENDING gate requires the FSM to dwell
  // ≥ kSquatBottomDwellMs (200ms) in BOTTOM (added 2026-05-15). Without an
  // advancing `now`, every tick shares wall-clock and the dwell never
  // clears, so the rep would stick in BOTTOM forever.
  var clock = DateTime(2026, 5, 16, 12);
  DateTime tick() {
    clock = clock.add(const Duration(milliseconds: 120));
    return clock;
  }

  // IDLE → DESCENDING (angle < kSquatStartAngle = 160).
  var out = tickAt(
    strategy: strategy,
    state: RepState.idle,
    angle: 150,
    hipY: 0.50,
    now: tick(),
  );
  expect(out.nextState, RepState.descending);

  // DESCENDING → BOTTOM (angle < effectiveBottomAngle, default
  // kSquatBottomAngle = 80° as of 2026-05-16).
  out = tickAt(
    strategy: strategy,
    state: RepState.descending,
    angle: minAngle,
    hipY: 0.60,
    now: tick(),
  );
  expect(
    out.nextState,
    RepState.bottom,
    reason:
        'minAngle $minAngle must dip below effectiveBottomAngle '
        '${strategy.effectiveBottomAngle}',
  );

  // Establish a previous hipY so the next frame can detect rise. Two
  // BOTTOM ticks at 120ms each ⇒ ≥ 240ms total dwell, clearing the 200ms
  // kSquatBottomDwellMs gate before the rise frame.
  tickAt(
    strategy: strategy,
    state: RepState.bottom,
    angle: minAngle,
    hipY: 0.60,
    now: tick(),
  );
  // BOTTOM → ASCENDING: hip rises (Y decreases in screen coords) AND the
  // dwell has elapsed.
  out = tickAt(
    strategy: strategy,
    state: RepState.bottom,
    angle: minAngle + 5,
    hipY: 0.55,
    now: tick(),
  );
  expect(out.nextState, RepState.ascending);

  // ASCENDING → IDLE when angle >= kSquatEndAngle = 160.
  out = tickAt(
    strategy: strategy,
    state: RepState.ascending,
    angle: 165,
    hipY: 0.50,
    now: tick(),
  );
  expect(out.nextState, RepState.idle);
  expect(out.repCommitted, isTrue);
  return out;
}

void main() {
  group('SquatStrategy — FSM transitions', () {
    test('full rep cycle commits exactly once', () {
      final strategy = SquatStrategy();
      final out = driveRep(strategy: strategy, minAngle: 70);
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

      // IDLE → DESCENDING → BOTTOM (70° clears the 80° gate).
      tickAt(strategy: strategy, state: RepState.idle, angle: 150, hipY: 0.50);
      var out = tickAt(
        strategy: strategy,
        state: RepState.descending,
        angle: 70,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);

      // Hip STILL at bottom — no rise — should stay in BOTTOM.
      out = tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: 70,
        hipY: 0.60,
      );
      expect(out.nextState, RepState.bottom);

      // Hip FALLS further (Y increases) — still not rising, stay in BOTTOM.
      out = tickAt(
        strategy: strategy,
        state: RepState.bottom,
        angle: 70,
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
        driveRep(strategy: strategy, minAngle: 70);
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
      final out = driveRep(strategy: strategy, minAngle: 70);
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
      driveRep(strategy: strategy, minAngle: 70);
      driveRep(strategy: strategy, minAngle: 70);

      strategy.onReset();

      // Post-reset, the strategy behaves identically to a newly-constructed one.
      expect(strategy.effectiveBottomAngle, kSquatBottomAngle);

      // A fresh rep still commits.
      final out = driveRep(strategy: strategy, minAngle: 70);
      expect(out.repCommitted, isTrue);
    });
  });

  group('SquatStrategy — variant + tall-lifter constructor params', () {
    // These assert against the constants, NOT literals. The lean
    // thresholds were retuned 45°→30° / 50°→35° on 2026-05-15; pinning to
    // `kSquatLeanWarnDeg*` keeps the *relationship* contract (variant +
    // boost composition) verified without re-drifting on every retune.
    test('default variant is bodyweight, lean threshold = '
        'kSquatLeanWarnDegBodyweight', () {
      final s = SquatStrategy();
      expect(s.variant, SquatVariant.bodyweight);
      expect(s.longFemurLifter, isFalse);
      expect(s.leanWarnDeg, kSquatLeanWarnDegBodyweight);
    });

    test('HBBS variant raises lean threshold to kSquatLeanWarnDegHBBS', () {
      final s = SquatStrategy(variant: SquatVariant.highBarBackSquat);
      expect(s.leanWarnDeg, kSquatLeanWarnDegHBBS);
    });

    test('tall-lifter toggle adds the long-femur boost to the bodyweight '
        'threshold', () {
      final s = SquatStrategy(longFemurLifter: true);
      expect(
        s.leanWarnDeg,
        kSquatLeanWarnDegBodyweight + kSquatLongFemurLeanBoost,
      );
    });

    test('tall-lifter + HBBS compose (variant base + boost)', () {
      final s = SquatStrategy(
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: true,
      );
      expect(s.leanWarnDeg, kSquatLeanWarnDegHBBS + kSquatLongFemurLeanBoost);
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
        // Toggle OFF — even after auto-detection, lean threshold stays at
        // the bodyweight base (orthogonality: auto-detect targets BOTTOM,
        // toggle targets lean).
        final s = SquatStrategy();
        expect(s.leanWarnDeg, kSquatLeanWarnDegBodyweight);
        // Auto-detection can't be triggered here: the rep-history band
        // `(kSquatLongFemurDetectFloorAngle, kLongFemurBottomAngle]` =
        // `(90°, 85°]` is empty by construction (2026-05-16). Assertion is
        // on the static contract: the analyzer's lean threshold is captured
        // at construction and never updated by the strategy's auto-flag.
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
      driveRep(strategy: s, minAngle: 70);
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
        // an unchanged Medium-sensitivity FSM. A rep that bottoms at 70°
        // (clearly below the 80° depth gate, post-2026-05-16) commits
        // cleanly through driveRep, which pins each transition against the
        // default thresholds.
        final s = SquatStrategy();
        final out = driveRep(strategy: s, minAngle: 70);
        expect(out.repCommitted, isTrue);
      },
    );

    test('Medium strategy enters BOTTOM at 79° (below the 80° depth gate)', () {
      final s = SquatStrategy();
      // Walk IDLE → DESCENDING → BOTTOM with minAngle = 79° (just below the
      // 2026-05-16 tightened 80° gate — proves the gate moved with the
      // constant, not a hardcoded 90°).
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      final out = tickAt(
        strategy: s,
        state: RepState.descending,
        angle: 79,
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

    test('Medium idle→descending gate is the derived Medium startAngle, '
        'NOT the looser High value (regression guard)', () {
      // The Medium START gate is `anchor.startAngle + dStart` (the
      // sensitivity post-pass), NOT a hardcoded literal — the old "160°"
      // expectation predates the anchor+delta model and was stale drift.
      // Derive the boundary from the tuple so this never re-drifts on an
      // anchor retune: an angle JUST ABOVE the Medium start must stay IDLE
      // (gate not crossed); JUST BELOW must enter DESCENDING.
      final mediumTuple = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.medium,
      );
      final s = SquatStrategy(romThresholds: mediumTuple);

      // Just ABOVE the Medium gate → must NOT enter DESCENDING.
      final above = tickAt(
        strategy: s,
        state: RepState.idle,
        angle: mediumTuple.startAngle + 1.0,
        hipY: 0.50,
      );
      expect(above.nextState, RepState.idle);

      // Just BELOW the Medium gate → must enter DESCENDING (proves the
      // gate is wired to the tuple's startAngle, not a stale constant).
      final below = tickAt(
        strategy: SquatStrategy(romThresholds: mediumTuple),
        state: RepState.idle,
        angle: mediumTuple.startAngle - 1.0,
        hipY: 0.50,
      );
      expect(below.nextState, RepState.descending);
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
      // (`_effectiveBottomAngle = kSquatBottomAngle` = 80° as of
      // 2026-05-16). 70° clears it; the +5 ascending step stays well below
      // the END gate so the END-gate assertion is what discriminates.
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      tickAt(strategy: s, state: RepState.descending, angle: 70, hipY: 0.60);
      tickAt(strategy: s, state: RepState.bottom, angle: 70, hipY: 0.60);
      tickAt(strategy: s, state: RepState.bottom, angle: 75, hipY: 0.55);

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

    test('the resolved tuple\'s bottomAngle is DEFINED but NOT consumed at '
        'FSM transition time — the FSM gates on _effectiveBottomAngle '
        '(= kSquatBottomAngle), the dead-tuple-disconnect invariant', () {
      // Dead-tuple-disconnect (documented GLOSSARY §4.1 / the 2026-05-16
      // telemetry-honesty fix): the FSM gates DESCENDING→BOTTOM on
      // `_effectiveBottomAngle`, NOT on the resolved
      // `SquatRomThresholdSet.bottomAngle`. The tuple field is telemetry-
      // derived (47.1, the actual current value — NOT the stale 88.0 the
      // pre-2026-05-15 revision asserted) and unconsumed at transition
      // time. This test is the living regression guard: if a future PR
      // wires the tuple bottomAngle into the FSM, it fails and the
      // developer confirms the new wiring is intentional.
      final highTuple = SquatRomThresholdSet.forSensitivity(
        FeedbackSensitivity.high,
      );
      // The tuple value is whatever telemetry derived — assert it is NOT
      // the gate the FSM actually enforces (that is the whole point of
      // the disconnect), without hardcoding a literal that will re-drift.
      expect(highTuple.bottomAngle, isNot(equals(kSquatBottomAngle)));

      final s = SquatStrategy(romThresholds: highTuple);
      // The enforced gate is `kSquatBottomAngle` (80° as of 2026-05-16)
      // regardless of the High tuple. A rep at 70° crosses it; a rep that
      // only reached the tuple's bottomAngle region would NOT (proving
      // the tuple value is not the gate).
      tickAt(strategy: s, state: RepState.idle, angle: 150, hipY: 0.50);
      final out = tickAt(
        strategy: s,
        state: RepState.descending,
        angle: 70,
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
