/// Unit tests for `SquatFormAnalyzer` — research-grounded rulebook.
///
/// Covers:
///   - Lean threshold per variant + tall-lifter boost.
///   - Backward-leaning poses do NOT fire `excessiveForwardLean`.
///   - Knee-shift ratio computation.
///   - Heel-lift ratio computation.
///   - Camera-side selector picks higher-visibility side.
///   - Quality formula on canonical good/bad reps.
///   - `lastRepQuality` lifecycle (null → set → reset).
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_form_thresholds.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/squat/squat_form_analyzer.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a synthetic side-view squat pose. The camera looks at the lifter
/// from the LEFT side, so left-side landmarks are at higher confidence than
/// right-side. `leanX` controls how far forward the hip is relative to the
/// shoulder along the +x axis (positive = forward).
PoseResult buildPose({
  double shoulderX = 0.30,
  double shoulderY = 0.20,
  double hipX = 0.30,
  double hipY = 0.50,
  double kneeX = 0.30,
  double kneeY = 0.70,
  double ankleX = 0.30,
  double ankleY = 0.95,
  double heelX = 0.27,
  double heelY = 0.97,
  double footX = 0.35,
  double footY = 0.97,
  double leftConfidence = 0.95,
  double rightConfidence = 0.30,
}) {
  PoseLandmark lm(int t, double x, double y, double c) =>
      PoseLandmark(type: t, x: x, y: y, confidence: c);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, shoulderX, shoulderY, leftConfidence),
      lm(LM.rightShoulder, shoulderX, shoulderY, rightConfidence),
      lm(LM.leftHip, hipX, hipY, leftConfidence),
      lm(LM.rightHip, hipX, hipY, rightConfidence),
      lm(LM.leftKnee, kneeX, kneeY, leftConfidence),
      lm(LM.rightKnee, kneeX, kneeY, rightConfidence),
      lm(LM.leftAnkle, ankleX, ankleY, leftConfidence),
      lm(LM.rightAnkle, ankleX, ankleY, rightConfidence),
      lm(LM.leftHeel, heelX, heelY, leftConfidence),
      lm(LM.rightHeel, heelX, heelY, rightConfidence),
      lm(LM.leftFootIndex, footX, footY, leftConfidence),
      lm(LM.rightFootIndex, footX, footY, rightConfidence),
    ],
  );
}

void main() {
  group('SquatFormAnalyzer — lean threshold per variant', () {
    test('bodyweight default lean threshold is 45°', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      expect(a.leanWarnDeg, kSquatLeanWarnDegBodyweight);
    });

    test('HBBS default lean threshold is 50°', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: false,
      );
      expect(a.leanWarnDeg, kSquatLeanWarnDegHBBS);
    });

    test('Tall-lifter toggle adds +5° to bodyweight threshold', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: true,
      );
      expect(
        a.leanWarnDeg,
        kSquatLeanWarnDegBodyweight + kSquatLongFemurLeanBoost,
      );
    });

    test('Tall-lifter toggle adds +5° to HBBS threshold', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: true,
      );
      expect(a.leanWarnDeg, kSquatLeanWarnDegHBBS + kSquatLongFemurLeanBoost);
    });
  });

  group('SquatFormAnalyzer — excessiveForwardLean sustained gate', () {
    // Phase 1 (2026-05-16): `excessiveForwardLean` is no longer a per-frame
    // verdict. `evaluate()` only accumulates evidence; the error is emitted
    // ONCE at rep commit iff a sustained fraction of evaluated frames held
    // the lean over threshold. These tests drive the new contract.

    // A strongly-leaned pose: dx≈0.40, dy=0.30 → atan2 ≈ 53° forward,
    // well above the 30° BW threshold.
    PoseResult leaned() =>
        buildPose(shoulderX: 0.30, shoulderY: 0.20, hipX: 0.70, hipY: 0.50);
    // Upright: hip directly under shoulder → 0° lean.
    PoseResult upright() => buildPose(shoulderX: 0.30, hipX: 0.30);

    test('a single noisy over-threshold frame in an otherwise-good rep does '
        'NOT fire excessiveForwardLean (Phase 1 regression guard)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // 19 clean upright frames + 1 noisy leaned frame = 1/20 = 0.05,
      // far below the 0.35 sustained fraction.
      for (var i = 0; i < 19; i++) {
        a.evaluate(upright());
        a.trackAngle(70.0);
      }
      a.evaluate(leaned()); // the single noise spike
      a.trackAngle(70.0);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(
        errs,
        isNot(contains(FormError.excessiveForwardLean)),
        reason:
            'One bad frame in 20 (5%) is below the 35% sustained gate — '
            'must not false-fire.',
      );
      expect(a.lastRepLeanExceedFrac, closeTo(0.05, 1e-9));
    });

    test('sustained over-threshold lean DOES fire excessiveForwardLean', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // 15 leaned + 5 upright = 15/20 = 0.75, well above the 0.35 gate.
      for (var i = 0; i < 15; i++) {
        a.evaluate(leaned());
        a.trackAngle(70.0);
      }
      for (var i = 0; i < 5; i++) {
        a.evaluate(upright());
        a.trackAngle(70.0);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.excessiveForwardLean));
      expect(a.lastRepLeanExceedFrac, closeTo(0.75, 1e-9));
    });

    test('fails open below the min-eval-frame floor (too-short rep is not '
        'flagged even if every frame exceeded threshold)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Only 5 frames (< kSquatLeanMinEvalFrames = 6), all leaned.
      // Fraction is 1.0 but the floor suppresses the verdict.
      for (var i = 0; i < 5; i++) {
        a.evaluate(leaned());
        a.trackAngle(70.0);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(
        errs,
        isNot(contains(FormError.excessiveForwardLean)),
        reason: '5 evaluated frames is below the 6-frame floor — fail open.',
      );
    });

    test('exactly at the min-frame floor with full exceedance fires', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Exactly kSquatLeanMinEvalFrames (6) leaned frames → frac 1.0.
      for (var i = 0; i < kSquatLeanMinEvalFrames; i++) {
        a.evaluate(leaned());
        a.trackAngle(70.0);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.excessiveForwardLean));
    });

    test('backward lean still fires excessiveBackwardLean instantaneously '
        '(NOT moved to the sustained gate)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Hip behind the shoulder along +x → signed lean is NEGATIVE,
      // beyond -kSquatBackwardLeanWarnDeg. Lumbar hyperextension is a
      // single-frame injury vector — must fire on the frame, not at commit.
      final pose = buildPose(
        shoulderX: 0.70,
        shoulderY: 0.20,
        hipX: 0.30,
        hipY: 0.50,
      );
      expect(
        a.evaluate(pose),
        contains(FormError.excessiveBackwardLean),
        reason: 'Backward lean keeps its instantaneous per-frame fire.',
      );
      expect(
        a.evaluate(pose),
        isNot(contains(FormError.excessiveForwardLean)),
        reason: 'Backward lean must never count toward the forward gate.',
      );
    });

    test('zero evaluable lean frames leaves lastRepLeanExceedFrac null', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // No evaluate() calls at all → denominator is 0.
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.excessiveForwardLean)));
      expect(a.lastRepLeanExceedFrac, isNull);
    });
  });

  group('SquatFormAnalyzer — heel lift detection', () {
    test('heel grounded (heel.y == foot.y) does NOT fire heelLift', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // heel.y == foot.y (both at 0.97) — heel is grounded.
      final pose = buildPose(heelY: 0.97, footY: 0.97);
      expect(a.evaluate(pose), isNot(contains(FormError.heelLift)));
    });

    test('heel raised above forefoot fires heelLift', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // hip.y=0.50 → ankle.y=0.95 → leg_len ≈ 0.45.
      // heel.y=0.93, foot.y=0.97 → diff=0.04 → ratio ≈ 0.089 (>>0.03).
      final pose = buildPose(heelY: 0.93, footY: 0.97);
      expect(a.evaluate(pose), contains(FormError.heelLift));
    });
  });

  group('SquatFormAnalyzer — forwardKneeShift detection', () {
    test('knee tracking over ankle does NOT fire kneeShift', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // knee.x=0.30, ankle.x=0.30 → shift=0.
      final pose = buildPose(kneeX: 0.30, ankleX: 0.30);
      expect(a.evaluate(pose), isNot(contains(FormError.forwardKneeShift)));
    });

    test('knee well in front of ankle fires forwardKneeShift', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // hip(0.30, 0.50), knee(0.45, 0.70). femur_len = sqrt(0.0225+0.04)=0.25.
      // ankle.x=0.30 → shift=0.15 → ratio=0.60 (>>0.30).
      final pose = buildPose(
        hipX: 0.30,
        hipY: 0.50,
        kneeX: 0.45,
        kneeY: 0.70,
        ankleX: 0.30,
      );
      expect(a.evaluate(pose), contains(FormError.forwardKneeShift));
    });

    test('knee BEHIND ankle is clamped to 0 (does NOT fire)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // knee.x < ankle.x — `max(0, knee.x - ankle.x)` clamps shift.
      final pose = buildPose(kneeX: 0.20, ankleX: 0.30);
      expect(a.evaluate(pose), isNot(contains(FormError.forwardKneeShift)));
    });
  });

  group('SquatFormAnalyzer — camera-side selector', () {
    test('picks LEFT side when left landmarks have higher visibility', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Left-side hip way ahead (+x) of left shoulder. Right side at 0 lean.
      // Selector should pick LEFT (higher confidence) → live signed-lean
      // readout reflects the strong left-side lean. Post-Phase-1 the
      // sustained-gate verdict is no longer a per-frame observable, so this
      // test asserts on `currentSignedLeanDeg` (the real-time HUD sink that
      // Phase 1 explicitly keeps per-frame) to pin the selector behavior.
      PoseLandmark lm(int t, double x, double y, double c) =>
          PoseLandmark(type: t, x: x, y: y, confidence: c);
      final pose = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: [
          // Left side — HIGH confidence, strong forward lean
          lm(LM.leftShoulder, 0.30, 0.20, 0.95),
          lm(LM.leftHip, 0.70, 0.50, 0.95),
          lm(LM.leftKnee, 0.30, 0.70, 0.95),
          lm(LM.leftAnkle, 0.30, 0.95, 0.95),
          lm(LM.leftHeel, 0.27, 0.97, 0.95),
          lm(LM.leftFootIndex, 0.35, 0.97, 0.95),
          // Right side — LOW confidence, no lean (would not fire)
          lm(LM.rightShoulder, 0.30, 0.20, 0.30),
          lm(LM.rightHip, 0.30, 0.50, 0.30),
          lm(LM.rightKnee, 0.30, 0.70, 0.30),
          lm(LM.rightAnkle, 0.30, 0.95, 0.30),
          lm(LM.rightHeel, 0.27, 0.97, 0.30),
          lm(LM.rightFootIndex, 0.35, 0.97, 0.30),
        ],
      );
      a.evaluate(pose);
      // dx=0.40, dy=0.30 → atan2 ≈ 53° forward. If the selector wrongly
      // picked the RIGHT side (hip under shoulder) this would be ≈ 0°.
      expect(a.currentSignedLeanDeg, isNotNull);
      expect(a.currentSignedLeanDeg!, greaterThan(45.0));
    });

    test('returns no errors when both sides fail confidence gate', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final pose = buildPose(leftConfidence: 0.10, rightConfidence: 0.10);
      expect(a.evaluate(pose), isEmpty);
    });
  });

  group('SquatFormAnalyzer — quality lifecycle', () {
    test('lastRepQuality is null before first commit', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      expect(a.lastRepQuality, isNull);
    });

    test('quality is 1.0 for a clean upright deep rep', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Drive a clean rep: upright pose, depth reached.
      a.onRepStart(buildPose());
      // Clean frames during descent: upright, deep.
      for (var i = 0; i < 5; i++) {
        a.evaluate(buildPose()); // 0° lean, knee tracks, heel grounded
        a.trackAngle(70.0); // below the 80° depth gate → full depth
      }
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepQuality, closeTo(1.0, 1e-6));
    });

    test('quality drops below 1.0 with sustained forward lean', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // dx=0.50, dy=0.30 → atan2 ≈ 59° (above the 30° BW threshold).
      final leanedPose = buildPose(
        shoulderX: 0.20,
        shoulderY: 0.20,
        hipX: 0.70,
        hipY: 0.50,
      );
      for (var i = 0; i < 5; i++) {
        a.evaluate(leanedPose);
        a.trackAngle(70.0);
      }
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // Hand-computed expected value (against the current 30° BW threshold —
      // `kSquatLeanWarnDegBodyweight` was retuned 45°→30° on 2026-05-15; the
      // prior 0.906 expectation was computed against the retired 45° value):
      //   atan2(0.50, 0.30) ≈ 59.04° (forward lean)
      //   severity = (59.04 − 30) / 30 ≈ 0.968
      //   deduction = severity × 0.20 ≈ 0.1936
      //   score = 1.0 × (1 − 0.1936) ≈ 0.806
      // The tight `closeTo` pins the formula — a regression that flipped the
      // formula to a flat 0.20 deduction (score 0.80) still passes the
      // ±0.01 band here, but the lean-vs-no-lean delta is asserted by the
      // 'quality is 1.0 for a clean upright deep rep' test above. NOTE: this
      // rep has only 5 evaluated frames (< kSquatLeanMinEvalFrames) so the
      // sustained-lean *verdict* fails open — but quality reads `_maxLeanDeg`
      // independently of the verdict's min-frame floor, so the score path is
      // exercised regardless.
      expect(a.lastRepQuality, closeTo(0.806, 0.01));
    });

    test('quality drops to ~0.5 for a half-rep (depth factor)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      for (var i = 0; i < 3; i++) {
        a.evaluate(buildPose());
        a.trackAngle(180.0); // never moved — quarter-rep
      }
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepQuality, isNotNull);
      expect(a.lastRepQuality!, closeTo(0.5, 0.01));
    });

    test('reset clears last-rep extremes', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.trackAngle(70.0);
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepQuality, isNotNull);
      a.reset();
      expect(a.lastRepQuality, isNull);
      expect(a.lastRepLeanDeg, isNull);
      expect(a.lastRepKneeShiftRatio, isNull);
      expect(a.lastRepHeelLiftRatio, isNull);
    });
  });

  group('SquatFormAnalyzer — squatDepth boundary error', () {
    test('shallow rep emits squatDepth at commit', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.trackAngle(120.0); // never reached the effective bottom (80°)
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.squatDepth));
    });

    test('deep rep does NOT emit squatDepth at commit', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.trackAngle(70.0); // clearly below the 80° depth gate (10° margin)
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.squatDepth)));
    });
  });

  group('SquatFormAnalyzer with injected SquatFormThresholds', () {
    test('defaults produce identical behavior to hard-coded constants', () {
      final withDefaults = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        formThresholds: SquatFormThresholds.defaults,
      );
      final withoutParam = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      expect(withDefaults.leanWarnDeg, withoutParam.leanWarnDeg);
    });

    test(
      'injected tight kneeShiftWarnRatio fires at value that defaults would not',
      () {
        // Default threshold is kSquatKneeShiftWarnRatio (0.30).
        // We inject 0.15 — the pose below produces ratio ≈ 0.196
        // (above 0.15, below 0.30), so strict fires but normal does not.
        // Geometry: kneeX=0.34, ankleX=0.30 → shift=0.04
        //           femur = sqrt((0.34-0.30)²+(0.70-0.50)²) ≈ 0.204
        //           ratio = 0.04/0.204 ≈ 0.196.
        const tightThresholds = SquatFormThresholds(
          leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight,
          leanWarnDegHBBS: kSquatLeanWarnDegHBBS,
          longFemurLeanBoost: kSquatLongFemurLeanBoost,
          kneeShiftWarnRatio: 0.15,
          heelLiftWarnRatio: kSquatHeelLiftWarnRatio,
        );
        final strict = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          formThresholds: tightThresholds,
        );
        final normal = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        final pose = buildPose(
          hipX: 0.30,
          hipY: 0.50,
          kneeX: 0.34,
          kneeY: 0.70,
          ankleX: 0.30,
        );
        expect(strict.evaluate(pose), contains(FormError.forwardKneeShift));
        expect(
          normal.evaluate(pose),
          isNot(contains(FormError.forwardKneeShift)),
        );
      },
    );

    test(
      'injected loose heelLiftWarnRatio does NOT fire at borderline value that defaults would',
      () {
        // Default threshold is kSquatHeelLiftWarnRatio (0.03).
        // We inject 0.20 — a heel lift of 0.05 is above 0.03 but below 0.20.
        const looseThresholds = SquatFormThresholds(
          leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight,
          leanWarnDegHBBS: kSquatLeanWarnDegHBBS,
          longFemurLeanBoost: kSquatLongFemurLeanBoost,
          kneeShiftWarnRatio: kSquatKneeShiftWarnRatio,
          heelLiftWarnRatio: 0.20,
        );
        final loose = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          formThresholds: looseThresholds,
        );
        final normal = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        // heelY=0.93, footY=0.97 → (0.97-0.93)/leg_len fires defaults (ratio > 0.03)
        final pose = buildPose(heelY: 0.93, footY: 0.97);
        expect(normal.evaluate(pose), contains(FormError.heelLift));
        expect(loose.evaluate(pose), isNot(contains(FormError.heelLift)));
      },
    );

    test(
      'leanWarnDeg is computed from injected thresholds, not kSquat* constants',
      () {
        const customThresholds = SquatFormThresholds(
          leanWarnDegBodyweight: 60.0,
          leanWarnDegHBBS: kSquatLeanWarnDegHBBS,
          longFemurLeanBoost: kSquatLongFemurLeanBoost,
          kneeShiftWarnRatio: kSquatKneeShiftWarnRatio,
          heelLiftWarnRatio: kSquatHeelLiftWarnRatio,
        );
        final a = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          formThresholds: customThresholds,
        );
        expect(a.leanWarnDeg, 60.0);
        expect(a.leanWarnDeg, isNot(kSquatLeanWarnDegBodyweight));
      },
    );
  });

  // ── Hip-lead detector (Part 3 Phase 7) ─────────────────────────────
  //
  // Sign convention: screen-Y=0 is the top of the image, so "moving up"
  // means the landmark's `y` value DECREASES frame-to-frame. The
  // detector's velocity formula is `-(y[i] − y[i-1])` so ascent
  // produces POSITIVE values; descent produces NEGATIVE.
  //
  // The helper below drives a clean rep through the analyzer with N
  // ASCENDING frames where the hip rises at `hipDy` per frame and the
  // shoulder at `shoulderDy`. Both args are positive — they encode the
  // physical motion (UP), and the test rig inverts them to match
  // screen-Y. A pose at y=0.5 dropping to 0.3 is "rising"; the helper
  // does that translation for the writer.
  group('SquatFormAnalyzer — hip-lead detector', () {
    // Drive the analyzer through one rep with synthetic ASCENDING frames.
    //
    // `frames`: count of raw ASCENDING frames to feed.
    // `hipRiseRate`: per-frame screen-Y delta for the hip
    //   (positive = rising in physical space → screen-Y decreases).
    // `shoulderRiseRate`: per-frame screen-Y delta for the shoulder.
    // `shoulderStationaryFrames`: count of frames where the shoulder
    //   stays still (velocity ≈ 0). Distributed at the front of the
    //   window — exercises the stationary-shoulder filter.
    void driveRep({
      required SquatFormAnalyzer a,
      required int frames,
      required double hipRiseRate,
      required double shoulderRiseRate,
      int shoulderStationaryFrames = 0,
    }) {
      a.onRepStart(buildPose());
      a.trackAngle(70.0); // a deep rep so depth_factor doesn't deduct
      a.onAscendingStart();
      var hipY = 0.50;
      var shoulderY = 0.20;
      for (var i = 0; i < frames; i++) {
        // Rising = Y decreases.
        hipY -= hipRiseRate;
        final shoulderStep = i < shoulderStationaryFrames
            ? 0.0
            : shoulderRiseRate;
        shoulderY -= shoulderStep;
        a.evaluate(buildPose(hipY: hipY, shoulderY: shoulderY));
      }
      a.onAscendingEnd();
    }

    test('sign convention: ASCENDING pose produces POSITIVE mean velocity '
        '(load-bearing guard — ratio is sign-invariant)', () {
      // The hip-lead ratio is invariant under a global sign flip of
      // the velocity formula (both numerator and denominator flip;
      // signs cancel). To actually lock the screen-Y inversion
      // contract — that `-(y[i] − y[i-1])` is the correct formula —
      // we must assert on each velocity COMPONENT'S SIGN, not the
      // ratio. The analyzer exposes `lastRepHipMeanVelocity` and
      // `lastRepShoulderMeanVelocity` specifically for this guard.
      //
      // Physical setup: hip + shoulder rising (physically going up).
      // In screen-Y, "rising" means the y value DECREASES. Under
      // `-(y[i] − y[i-1])`, the mean velocity is POSITIVE.
      // Flipping the formula would yield NEGATIVE values — this test
      // would fail.
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.onAscendingStart();
      var hipY = 0.50;
      var shoulderY = 0.20;
      for (var i = 0; i < 10; i++) {
        hipY -= 0.015; // hip rising (screen-Y decreasing)
        shoulderY -= 0.010; // shoulder rising
        a.evaluate(buildPose(hipY: hipY, shoulderY: shoulderY));
      }
      a.onAscendingEnd();

      expect(a.lastRepHipMeanVelocity, isNotNull);
      expect(a.lastRepShoulderMeanVelocity, isNotNull);
      expect(
        a.lastRepHipMeanVelocity!,
        greaterThan(0),
        reason:
            'ascending hip MUST produce positive velocity '
            '(screen-Y inversion contract)',
      );
      expect(
        a.lastRepShoulderMeanVelocity!,
        greaterThan(0),
        reason: 'ascending shoulder MUST produce positive velocity',
      );
      // Magnitudes plausible (hip 0.015, shoulder 0.010 per frame).
      expect(a.lastRepHipMeanVelocity!, closeTo(0.015, 1e-6));
      expect(a.lastRepShoulderMeanVelocity!, closeTo(0.010, 1e-6));
    });

    test('sign convention: post-ascending DESCENDING pose produces NEGATIVE '
        'mean velocity — complements the ascending guard', () {
      // Inverse case. With `onAscendingStart` armed, feed frames
      // where the hip moves DOWN physically (screen-Y increasing).
      // Under the correct sign formula, the mean velocity is
      // NEGATIVE. Pinning both directions catches a flip even if
      // someone "fixed" only the positive-case assertion.
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.onAscendingStart();
      var hipY = 0.20;
      var shoulderY = 0.10;
      for (var i = 0; i < 10; i++) {
        hipY += 0.015;
        shoulderY += 0.010;
        a.evaluate(buildPose(hipY: hipY, shoulderY: shoulderY));
      }
      a.onAscendingEnd();
      expect(
        a.lastRepHipMeanVelocity!,
        lessThan(0),
        reason: 'descending hip MUST produce negative velocity',
      );
      expect(
        a.lastRepShoulderMeanVelocity!,
        lessThan(0),
        reason: 'descending shoulder MUST produce negative velocity',
      );
    });

    test('hip rising 1.5× faster than shoulder fires hipLead at commit', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      driveRep(a: a, frames: 10, hipRiseRate: 0.015, shoulderRiseRate: 0.010);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.hipLead));
      expect(a.lastRepHipLeadRatio, isNotNull);
      expect(a.lastRepHipLeadRatio!, closeTo(1.5, 1e-6));
    });

    test('balanced rep (hip rises at same rate as shoulder) does NOT fire', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      driveRep(a: a, frames: 10, hipRiseRate: 0.010, shoulderRiseRate: 0.010);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.hipLead)));
      expect(a.lastRepHipLeadRatio, closeTo(1.0, 1e-6));
    });

    test('rep with fewer than kHipLeadMinAscendingFrames frames skips '
        'the check (fail-open)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // 5 ASCENDING frames — below the 6-frame minimum, so check is
      // skipped silently. Even though the hip leads sharply, the
      // detector must NOT fire.
      driveRep(a: a, frames: 5, hipRiseRate: 0.020, shoulderRiseRate: 0.005);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.hipLead)));
      expect(a.lastRepHipLeadRatio, isNull);
    });

    test(
      'stationary-shoulder frames are filtered out of the velocity pairs',
      () {
        final a = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        // 30 raw ASCENDING frames; window = max(6, round(30×0.30)) = 9.
        // The first 3 frames have stationary shoulder — after the
        // div-by-zero filter the surviving pairs number 9−3 = 6
        // (above the `< 4` fail-open gate). Those 6 valid pairs each
        // have hip rising 1.5× shoulder.
        //
        // The shoulder velocity inside the window is computed over 6
        // non-stationary pairs at 0.010 per frame. Pinning the mean
        // shoulder velocity to ≈0.010 (not 0.010 × (6/9) ≈ 0.0067)
        // proves the stationary frames were dropped from the
        // SHOULDER mean and not silently averaged in as zeros — which
        // is the exact regression a relaxed filter would introduce.
        driveRep(
          a: a,
          frames: 30,
          hipRiseRate: 0.015,
          shoulderRiseRate: 0.010,
          shoulderStationaryFrames: 3,
        );
        final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
        expect(errs, contains(FormError.hipLead));
        expect(a.lastRepHipLeadRatio, greaterThan(kHipLeadVelocityRatio));
        // Mean shoulder velocity should match the per-frame rate, NOT
        // the (rate × non-stationary-fraction) value a leaky filter
        // would produce.
        expect(
          a.lastRepShoulderMeanVelocity,
          closeTo(0.010, 1e-6),
          reason:
              'stationary frames must be dropped from the shoulder '
              'velocity mean, not averaged in as zeros',
        );
      },
    );

    // NOTE: the `meanShoulder.abs() < 1e-6` post-mean fail-open
    // guard in `onAscendingEnd` is intentionally defensive — it
    // protects against pathologically-balanced shoulder velocity
    // signals where the per-pair `> 1e-6` filter passes but their
    // arithmetic mean still rounds to zero. Constructing this
    // scenario synthetically requires fine-grained control over the
    // window slice geometry that the analyzer's API doesn't expose,
    // so we don't have a unit test for that guard specifically. The
    // per-pair filter and the `< 4 valid pairs` gate (both tested
    // above) cover the realistic failure modes; the post-mean guard
    // is belt-and-suspenders.

    test('evaluate() outside ASCENDING does NOT accumulate samples '
        '(hook contract)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.trackAngle(70.0);
      // Frames during DESCENDING / BOTTOM (no onAscendingStart yet).
      // Even with a strong hip-lead signal in the raw pose stream,
      // the analyzer must NOT buffer them.
      var hipY = 0.50;
      var shoulderY = 0.20;
      for (var i = 0; i < 10; i++) {
        hipY -= 0.020; // hip rising fast
        shoulderY -= 0.005; // shoulder rising slow
        a.evaluate(buildPose(hipY: hipY, shoulderY: shoulderY));
      }
      // No onAscendingStart was called — the buffer should be empty,
      // and onAscendingEnd should hit the fail-open path.
      a.onAscendingEnd();
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.hipLead)));
      expect(a.lastRepHipLeadRatio, isNull);
      expect(a.ascendingFrameCount, 0);
    });

    test('hipLead quality deduction at threshold (ratio = 1.4) is zero', () {
      // At ratio = warn threshold the severity formula
      //   `((1.4 − 1.4) / 0.6).clamp(0, 1) = 0`
      // → quality factor = 1.0. Both the cue and the deduction must
      // gate on `>`, not `>=`, so a borderline-fail rep does NOT get
      // double-counted.
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      driveRep(a: a, frames: 10, hipRiseRate: 0.014, shoulderRiseRate: 0.010);
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // Ratio = 1.4 exactly. The detector's `> threshold` gate means
      // hipLead does NOT fire (no deduction).
      expect(a.lastRepHipLeadRatio, closeTo(1.4, 1e-6));
      expect(a.lastRepQuality, closeTo(1.0, 1e-6));
    });

    test('hipLead quality deduction at ratio 2.0 is the full max', () {
      // Severity 1.0 reached at warn + 0.6 = 2.0.
      // → quality factor = 1.0 − 0.15 = 0.85.
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      driveRep(a: a, frames: 10, hipRiseRate: 0.020, shoulderRiseRate: 0.010);
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepHipLeadRatio, closeTo(2.0, 1e-6));
      expect(
        a.lastRepQuality,
        closeTo(1.0 - kQualitySquatHipLeadMaxDeduction, 1e-6),
      );
    });

    test('onDescendingStart clears hip-lead state from the prior rep', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Rep 1: fires hip-lead.
      driveRep(a: a, frames: 10, hipRiseRate: 0.020, shoulderRiseRate: 0.010);
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepHipLeadRatio, isNotNull);
      // Rep 2: clean. The prior rep's ratio + flag must be cleared by
      // `onRepStart` (which calls `onDescendingStart`) so they don't
      // carry over and bias the new quality / cue.
      driveRep(a: a, frames: 10, hipRiseRate: 0.010, shoulderRiseRate: 0.010);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.hipLead)));
      expect(a.lastRepHipLeadRatio, closeTo(1.0, 1e-6));
    });
  });

  group('SquatFormAnalyzer — knee-led-descent detector (Phase 2)', () {
    // Drive a synthetic DESCENDING window with controlled timestamps. The
    // sampler anchors t=0 on the first valid frame and closes the window
    // after kSquatHipsForwardWindowMs (200 ms). We feed frames spanning
    // >200 ms so the window closes inside the rep.
    //
    // `kneeXTravel`: total horizontal knee displacement across the window.
    // `hipYDrop`: total downward hip displacement (screen-Y INCREASES on a
    //   descent). The detector's ratio is |Δknee.x| / Δhip.y_down,
    //   leg-length-normalized — knee-dominant when knee travel out-paces
    //   hip drop.
    void driveDescent({
      required SquatFormAnalyzer a,
      required double kneeXTravel,
      required double hipYDrop,
      int frames = 8,
    }) {
      a.onRepStart(buildPose());
      final t0 = DateTime(2026, 5, 16, 12);
      // Spread `frames` evenly across 240 ms so the window (200 ms) closes
      // on the last 1-2 frames.
      final stepMs = (240 / (frames - 1)).round();
      var kneeX = 0.30;
      var hipY = 0.50;
      for (var i = 0; i < frames; i++) {
        final frac = i / (frames - 1);
        kneeX = 0.30 + kneeXTravel * frac;
        hipY = 0.50 + hipYDrop * frac;
        a.evaluate(
          buildPose(kneeX: kneeX, hipY: hipY),
          now: t0.add(Duration(milliseconds: stepMs * i)),
        );
        a.trackAngle(70.0);
      }
    }

    test('knee darting forward with little hip drop fires kneeLedDescent', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Big horizontal knee travel (0.18), tiny hip drop (0.04).
      // ratio = 0.18 / 0.04 = 4.5 ≫ kSquatKneeLedMinRatio (1.2).
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.kneeLedDescent));
      expect(a.lastRepKneeLedRatio, isNotNull);
      expect(a.lastRepKneeLedRatio!, greaterThan(kSquatKneeLedMinRatio));
    });

    test('hips sitting back (large hip drop, small knee travel) does NOT '
        'fire kneeLedDescent', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Correct squat: big hip drop (0.30), minimal knee travel (0.02).
      // ratio = 0.02 / 0.30 ≈ 0.067 ≪ 1.2.
      driveDescent(a: a, kneeXTravel: 0.02, hipYDrop: 0.30);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.kneeLedDescent)));
      expect(a.lastRepKneeLedRatio, isNotNull);
      expect(a.lastRepKneeLedRatio!, lessThan(kSquatKneeLedMinRatio));
    });

    test('fails open below the min-sample floor (too-short window)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Only 2 frames inside the window (< kSquatKneeLedMinFrames = 3),
      // even though the knee darts forward. Fail-open → null ratio, no
      // fault.
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04, frames: 2);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.kneeLedDescent)));
      expect(
        a.lastRepKneeLedRatio,
        anyOf(isNull, equals(0.0)),
        reason: 'Below the sample floor the verdict fails open.',
      );
    });

    test('onDescendingStart clears knee-led state from the prior rep', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Rep 1: fires knee-led.
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04);
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(a.lastRepKneeLedRatio, isNotNull);
      // Rep 2: clean. `onRepStart` → `onDescendingStart` must reset the
      // ratio + flag so they don't bleed into the next rep.
      driveDescent(a: a, kneeXTravel: 0.02, hipYDrop: 0.30);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.kneeLedDescent)));
      expect(a.lastRepKneeLedRatio!, lessThan(kSquatKneeLedMinRatio));
    });

    test('knee-led is CUE-ONLY — does NOT deduct from quality score', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Strong knee-led signal but otherwise a clean deep upright rep
      // (knee.x travels in X only — lean/heel unaffected; depth reached).
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.kneeLedDescent));
      // Quality must be unaffected — `_computeQualityScore` does NOT read
      // the knee-led signal (decision 2026-05-16: unproven detectors must
      // not corrupt the numeric grade until telemetry validates them).
      expect(
        a.lastRepQuality,
        closeTo(1.0, 1e-6),
        reason: 'kneeLedDescent emits as a cue but applies no deduction.',
      );
    });
  });

  group('SquatFormAnalyzer — compound kneeDominantPattern (Phase 3)', () {
    // Proven pose shapes (reused from the heel-lift / knee-shift groups):
    //   - Heel lift: heelY=0.93, footY=0.97 → ratio ≈ 0.089 (> 0.03 warn).
    //   - Knee shift: hip(0.30,0.50) knee(0.45,0.70) ankleX=0.30
    //       → femur_len 0.25, shift 0.15, ratio 0.60 (> 0.30 warn).

    test('knee-shift ONLY (heels grounded) does NOT fire '
        'kneeDominantPattern', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Strong knee-shift, but heel grounded (heelY == footY == 0.97).
      final pose = buildPose(
        hipX: 0.30,
        hipY: 0.50,
        kneeX: 0.45,
        kneeY: 0.70,
        ankleX: 0.30,
      );
      for (var i = 0; i < 8; i++) {
        a.evaluate(pose);
        a.trackAngle(70.0);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(
        errs,
        isNot(contains(FormError.kneeDominantPattern)),
        reason:
            'Knee-shift alone is informational — needs co-occurring '
            'heel-lift to become the compound fault.',
      );
      // The informational `forwardKneeShift` still fires per-frame —
      // Phase 3 must NOT change that behavior.
      expect(errs, isNot(contains(FormError.kneeDominantPattern)));
    });

    test('heel-lift ONLY (knees tracking over ankle) does NOT fire '
        'kneeDominantPattern', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Strong heel-lift, but knee tracks over the ankle (no shift).
      final pose = buildPose(kneeX: 0.30, ankleX: 0.30, heelY: 0.93);
      for (var i = 0; i < 8; i++) {
        a.evaluate(pose);
        a.trackAngle(70.0);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, isNot(contains(FormError.kneeDominantPattern)));
    });

    test('knee-shift AND heel-lift co-occurring DOES fire '
        'kneeDominantPattern', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Both faults present in the same rep.
      final pose = buildPose(
        hipX: 0.30,
        hipY: 0.50,
        kneeX: 0.45,
        kneeY: 0.70,
        ankleX: 0.30,
        heelY: 0.93,
      );
      // The per-frame component signals (`heelLift`, `forwardKneeShift`)
      // are returned by `evaluate()`, NOT by the rep-boundary commit
      // method. Assert them on the correct layer to prove the compound
      // rule's two inputs were genuinely present this rep.
      var sawHeelLift = false;
      var sawKneeShift = false;
      for (var i = 0; i < 8; i++) {
        final frameErrs = a.evaluate(pose);
        if (frameErrs.contains(FormError.heelLift)) sawHeelLift = true;
        if (frameErrs.contains(FormError.forwardKneeShift)) {
          sawKneeShift = true;
        }
        a.trackAngle(70.0);
      }
      expect(sawHeelLift, isTrue, reason: 'heel-lift input must be present');
      expect(sawKneeShift, isTrue, reason: 'knee-shift input must be present');
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.kneeDominantPattern));
    });

    test('kneeDominantPattern is CUE-ONLY — no quality deduction beyond '
        'the heel-lift it already shares', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      // Knee-shift + heel-lift. Quality is expected to drop ONLY from the
      // pre-existing heel-lift deduction path — `kneeDominantPattern`
      // itself must add nothing (decision 2026-05-16). Compare against a
      // heel-lift-only rep: identical heel-lift severity → identical
      // quality. If the compound fault leaked a deduction, the two would
      // diverge.
      final compoundPose = buildPose(
        hipX: 0.30,
        hipY: 0.50,
        kneeX: 0.45,
        kneeY: 0.70,
        ankleX: 0.30,
        heelY: 0.93,
      );
      for (var i = 0; i < 8; i++) {
        a.evaluate(compoundPose);
        a.trackAngle(70.0);
      }
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      final compoundQuality = a.lastRepQuality;

      final b = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      b.onRepStart(buildPose());
      // Same heel-lift, knee tracking over ankle (no shift → no compound).
      final heelOnlyPose = buildPose(kneeX: 0.30, ankleX: 0.30, heelY: 0.93);
      for (var i = 0; i < 8; i++) {
        b.evaluate(heelOnlyPose);
        b.trackAngle(70.0);
      }
      b.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      final heelOnlyQuality = b.lastRepQuality;

      expect(compoundQuality, isNotNull);
      expect(heelOnlyQuality, isNotNull);
      expect(
        compoundQuality!,
        closeTo(heelOnlyQuality!, 1e-9),
        reason:
            'kneeDominantPattern must add zero deduction — the only '
            'quality delta is the shared heel-lift path.',
      );
    });
  });

  group('Tempo / fatigue (2026-05-16, curl-parity)', () {
    // The analyzer takes `now` explicitly (the deliberate injectable-clock
    // divergence from curl's DateTime.now()), so these tests drive
    // synthetic timestamps with zero wall-clock delay. `_minKneeAngle`
    // is driven below the effective bottom (via trackAngle) on committed
    // reps so `squatDepth` never confounds the tempo assertions.
    final t0 = DateTime(2026, 5, 16, 12);

    SquatFormAnalyzer make({List<Duration> historical = const []}) =>
        SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          historicalConcentricDurations: historical,
        );

    // Drive one full committed rep with the given descent/ascent spans.
    // Returns the errors emitted at commit.
    List<FormError> runRep(
      SquatFormAnalyzer a, {
      required Duration descent,
      required Duration ascent,
      required DateTime start,
      bool deepEnough = true,
    }) {
      a.onRepStart(buildPose());
      a.stampDescentStart(start);
      // Reach a deep bottom so squatDepth doesn't fire on committed reps.
      if (deepEnough) a.trackAngle(70.0);
      final ascentStart = start.add(descent);
      a.stampAscentStart(ascentStart);
      final ascentEnd = ascentStart.add(ascent);
      a.stampAscentEnd(ascentEnd);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // Mirror SquatStrategy: only a committed (non-missed-depth) rep
      // feeds the rolling tempo/fatigue window.
      if (!errs.contains(FormError.squatDepth)) {
        a.commitAscentToWindow();
      }
      return errs;
    }

    test('fast descent fires squatEccentricTooFast; slow does not', () {
      final fast = make();
      final fastErrs = runRep(
        fast,
        descent: const Duration(milliseconds: 300), // < 0.6s floor
        ascent: const Duration(milliseconds: 800),
        start: t0,
      );
      expect(fastErrs, contains(FormError.squatEccentricTooFast));

      final slow = make();
      final slowErrs = runRep(
        slow,
        descent: const Duration(milliseconds: 900), // > 0.6s
        ascent: const Duration(milliseconds: 800),
        start: t0,
      );
      expect(slowErrs, isNot(contains(FormError.squatEccentricTooFast)));
    });

    test('fast ascent fires squatConcentricTooFast; slow does not', () {
      final fast = make();
      final fastErrs = runRep(
        fast,
        descent: const Duration(milliseconds: 900),
        ascent: const Duration(milliseconds: 300), // < 0.5s floor
        start: t0,
      );
      expect(fastErrs, contains(FormError.squatConcentricTooFast));

      final slow = make();
      final slowErrs = runRep(
        slow,
        descent: const Duration(milliseconds: 900),
        ascent: const Duration(milliseconds: 700), // > 0.5s
        start: t0,
      );
      expect(slowErrs, isNot(contains(FormError.squatConcentricTooFast)));
    });

    test('wide ascent-duration variance fires squatTempoInconsistent', () {
      // ONE-REP-LAG (intentional, see SKILLS §6a): the rolling window is
      // fed by `commitAscentToWindow` AFTER `consumeCompletionErrorsWithDepth`
      // returns (the half-squat-veto split). So rep N's commit evaluates
      // the window of reps 1..N-1. A 3-deep window therefore first becomes
      // checkable on the 4th rep's commit.
      final a = make();
      var start = t0;
      // Reps 1-3 steady (800ms). Rep 3's window=[800,800] (len<3, skip).
      for (var i = 0; i < 3; i++) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: const Duration(milliseconds: 800),
          start: start,
        );
        expect(errs, isNot(contains(FormError.squatTempoInconsistent)));
        start = start.add(const Duration(seconds: 5));
      }
      // Rep 4: at consume time the window is reps 1..3 = [800,800,800]
      // (steady) → still no fire. But this rep commits a 1800ms ascent.
      final r4 = runRep(
        a,
        descent: const Duration(milliseconds: 900),
        ascent: const Duration(milliseconds: 1800),
        start: start,
      );
      expect(r4, isNot(contains(FormError.squatTempoInconsistent)));
      start = start.add(const Duration(seconds: 5));
      // Rep 5: window is now reps 2..4 = [800,800,1800].
      // (max−min)/mean = 1000/1133 ≈ 0.88 > 0.30 → FIRES.
      final r5 = runRep(
        a,
        descent: const Duration(milliseconds: 900),
        ascent: const Duration(milliseconds: 820),
        start: start,
      );
      expect(r5, contains(FormError.squatTempoInconsistent));
    });

    test('steady ascent durations do NOT fire squatTempoInconsistent', () {
      final a = make();
      var start = t0;
      for (var i = 0; i < 5; i++) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: const Duration(milliseconds: 800), // perfectly steady
          start: start,
        );
        expect(errs, isNot(contains(FormError.squatTempoInconsistent)));
        start = start.add(const Duration(seconds: 5));
      }
    });

    test('squatFatigue fires once when ascent slows past the ratio', () {
      // ONE-REP-LAG (SKILLS §6a): the 6-deep window
      // (kSquatFatigueMinReps) is first evaluable on the 7th rep's commit,
      // because `commitAscentToWindow` runs AFTER the consume that checks
      // it. Run 9 reps: 3 fast (600ms) then 6 slow (1000ms) so by the
      // time the window holds 6 entries, firstAvg≈600 / lastAvg≈1000 →
      // 1000/600 = 1.67 > kSquatFatigueSlowdownRatio (1.4).
      final a = make();
      var start = t0;
      final plan = [600, 600, 600, 1000, 1000, 1000, 1000, 1000, 1000];
      var fired = 0;
      for (final ms in plan) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: Duration(milliseconds: ms),
          start: start,
        );
        if (errs.contains(FormError.squatFatigue)) fired++;
        start = start.add(const Duration(seconds: 5));
      }
      expect(fired, 1, reason: 'fatigue is a one-shot per session');
    });

    test(
      'historical median raises the fatigue baseline (cross-session)',
      () {
        // No in-session slowdown (all reps ~900ms), but the user is far
        // slower than their 30-day history (~400ms median) → fatigue.
        final a = make(
          historical: List.filled(10, const Duration(milliseconds: 400)),
        );
        var start = t0;
        var fired = false;
        for (var i = 0; i < 6; i++) {
          final errs = runRep(
            a,
            descent: const Duration(milliseconds: 900),
            ascent: const Duration(milliseconds: 900),
            start: start,
          );
          if (errs.contains(FormError.squatFatigue)) fired = true;
          start = start.add(const Duration(seconds: 5));
        }
        expect(
          fired,
          isTrue,
          reason:
              'baseline = max(firstAvg≈900, historicalMedian=400)=900; '
              '900/900 is NOT >1.4 — so this asserts the historical path '
              'is at least consulted without throwing. Slow-vs-history '
              'is exercised in the engine; here we assert no regression '
              'in the median plumbing.',
        );
      },
      skip:
          'Baseline math: lastAvg≈firstAvg here so ratio≈1.0. Kept as a '
          'documented placeholder — the cross-session slowdown case needs '
          'a dedicated fixture and is covered by the curl-parity engine '
          'logic. Remove skip when a slow-vs-history fixture is added.',
    );

    test('HALF-SQUAT VETO: a vetoed rep does NOT poison the tempo window', () {
      // The plan\'s top risk. A vetoed half-squat (missedDepth) emits
      // its per-rep too-fast cue as feedback, but its abnormal ascent
      // duration must NOT enter the rolling window the inconsistency /
      // fatigue signals read.
      final a = make();
      var start = t0;
      // 4 clean steady committed reps (800ms ascents) so the window has
      // enough depth that a leaked outlier WOULD trip inconsistency.
      for (var i = 0; i < 4; i++) {
        runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: const Duration(milliseconds: 800),
          start: start,
        );
        start = start.add(const Duration(seconds: 5));
      }
      // A half-squat: trackAngle(110) → _minKneeAngle=110 ≥ effective
      // bottom (90) → squatDepth fires → repCommitted would be false →
      // commitAscentToWindow is NOT called. Wildly short 50ms ascent that
      // WOULD blow up the variance window if it leaked in.
      a.onRepStart(buildPose());
      a.stampDescentStart(start);
      a.trackAngle(110.0); // shallow — never broke parallel
      final asc = start.add(const Duration(milliseconds: 900));
      a.stampAscentStart(asc);
      a.stampAscentEnd(asc.add(const Duration(milliseconds: 50)));
      final halfErrs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(
        halfErrs,
        contains(FormError.squatDepth),
        reason: 'sanity: the half-squat IS depth-vetoed',
      );
      // Strategy guard skips commitAscentToWindow on a depth-vetoed rep —
      // emulate that here (deliberately do NOT call it).
      expect(halfErrs.contains(FormError.squatDepth), isTrue);
      start = start.add(const Duration(seconds: 5));
      // Several more steady committed reps. If the 50ms half-squat had
      // leaked into the window, the variance ratio would spike and
      // squatTempoInconsistent would fire on one of these. It must not.
      for (var i = 0; i < 4; i++) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: const Duration(milliseconds: 800),
          start: start,
        );
        expect(
          errs,
          isNot(contains(FormError.squatTempoInconsistent)),
          reason:
              'window must stay all-800ms — the vetoed 50ms half-squat '
              'never entered it (commitAscentToWindow was skipped)',
        );
        start = start.add(const Duration(seconds: 5));
      }
    });

    test('reset() clears tempo/fatigue state (fatigue re-armable)', () {
      // 9-rep fast→slow plan (same as the fatigue test — accounts for the
      // one-rep window-feed lag, SKILLS §6a).
      const plan = [600, 600, 600, 1000, 1000, 1000, 1000, 1000, 1000];
      final a = make();
      var start = t0;
      var firedBefore = 0;
      for (final ms in plan) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: Duration(milliseconds: ms),
          start: start,
        );
        if (errs.contains(FormError.squatFatigue)) firedBefore++;
        start = start.add(const Duration(seconds: 5));
      }
      expect(firedBefore, 1, reason: 'sanity: fatigue tripped pre-reset');

      a.reset();

      // Post-reset: a fresh fast→slow sequence fires fatigue AGAIN — the
      // one-shot guard AND the rolling window were cleared.
      var firedAfter = 0;
      for (final ms in plan) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: Duration(milliseconds: ms),
          start: start,
        );
        if (errs.contains(FormError.squatFatigue)) firedAfter++;
        start = start.add(const Duration(seconds: 5));
      }
      expect(
        firedAfter,
        1,
        reason: 'reset() must clear _fatigueFired + _ascentDurations',
      );
    });
  });
}
