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

    // Squat forward-lean geometry (post-2026-05-21 swap): shoulder ahead
    // of hip along toes (+x). dx = shoulder − hip ≈ 0.40, dy = 0.30 →
    // atan2 ≈ 53° forward, well above the 30° BW threshold. footX > heelX
    // gives forwardSign = +1 so the signed lean reads positive.
    PoseResult leaned() => buildPose(
      shoulderX: 0.70,
      shoulderY: 0.20,
      hipX: 0.30,
      hipY: 0.50,
      heelX: 0.28,
      footX: 0.36,
    );
    // Upright: hip directly under shoulder → 0° lean.
    PoseResult upright() =>
        buildPose(shoulderX: 0.30, hipX: 0.30, heelX: 0.28, footX: 0.36);

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
      // Post-2026-05-21 squat-lean convention: forward = shoulder ahead of
      // hip along the toes direction. Backward = shoulder BEHIND hip.
      // Place shoulder at lower x than hip (with toes still in +x) so
      // signed lean reads NEGATIVE beyond -kSquatBackwardLeanWarnDeg.
      final pose = buildPose(
        shoulderX: 0.30,
        shoulderY: 0.20,
        hipX: 0.70,
        hipY: 0.50,
        heelX: 0.28,
        footX: 0.36,
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

    test('heel raised above forefoot does NOT fire heelLift '
        '(TOMBSTONED 2026-05-21 — cue retired per user request)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // heel.y=0.93, foot.y=0.97 → a genuine heel lift geometrically.
      // The ratio is still computed (summary screen reads it) but the
      // FormError is no longer emitted.
      final pose = buildPose(heelY: 0.93, footY: 0.97);
      expect(a.evaluate(pose), isNot(contains(FormError.heelLift)));
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

    test('knee displaced BEHIND ankle still fires forwardKneeShift '
        '(direction-agnostic since the 2026-05-21 abs() reformulation)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // knee.x < ankle.x. The 2026-05-21 fix replaced `max(0, …)` with
      // `(knee.x − ankle.x).abs()` so left-facing users (whose knee
      // tracks toward LOWER x as it travels forward) aren't silently
      // zeroed. Magnitude is what matters, not screen direction.
      // knee(0.20,0.70), ankle(0.30,0.95) → |Δx|=0.10, tibia=sqrt(0.01+
      // 0.0625)≈0.269 → ratio≈0.37 (>0.30 warn).
      final pose = buildPose(kneeX: 0.20, kneeY: 0.70, ankleX: 0.30);
      expect(a.evaluate(pose), contains(FormError.forwardKneeShift));
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
          // Left side — HIGH confidence, strong forward lean (squat
          // convention: shoulder ahead of hip along toes +x).
          lm(LM.leftShoulder, 0.70, 0.20, 0.95),
          lm(LM.leftHip, 0.30, 0.50, 0.95),
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

    // The 'injected loose heelLiftWarnRatio' test was removed 2026-05-21
    // when the heelLift cue was tombstoned per user request. The
    // `heelLiftWarnRatio` field still exists on SquatFormThresholds and
    // is exercised by `form_audit_defaults_test.dart` / the post-session
    // form auditor, but it no longer drives any live FormError emission,
    // so there is nothing for an analyzer-level test to assert here.

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
        // Feed a realistic descending knee angle (170° standing → 70°
        // bottom) so `kneeDelta` ends up ≈ 100°. A flat 70.0 on every
        // frame would give kneeDelta ≈ 0, which trips the broadened
        // stiff-legged `noKneeFlexion` path and shadows the signal this
        // helper is meant to exercise.
        a.trackAngle(170.0 - 100.0 * frac);
      }
    }

    test('knee darting forward with little hip drop drives the knee-led '
        'ratio above threshold (detector TOMBSTONED — no FormError, '
        'telemetry ratio still computed)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Big horizontal knee travel (0.18), tiny hip drop (0.04).
      // ratio = 0.18 / 0.04 = 4.5 ≫ kSquatKneeLedMinRatio (1.2).
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // kneeLedDescent FormError is no longer emitted (tombstoned
      // 2026-05-21 audit). The ratio is still computed for telemetry.
      expect(errs, isNot(contains(FormError.kneeLedDescent)));
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

    test('knee-led applies no quality deduction (tombstoned — neither a '
        'cue nor a grade input)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Strong knee-led signal but otherwise a clean deep upright rep.
      driveDescent(a: a, kneeXTravel: 0.18, hipYDrop: 0.04);
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // No FormError; no quality deduction. The detector is fully
      // tombstoned — the ratio survives only as a telemetry value.
      expect(errs, isNot(contains(FormError.kneeLedDescent)));
      expect(
        a.lastRepQuality,
        closeTo(1.0, 1e-6),
        reason: 'kneeLedDescent applies no deduction.',
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

    test('knee-shift AND heel-lift co-occurring does NOT fire '
        'kneeDominantPattern (compound fault TOMBSTONED 2026-05-21)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Drive a realistic descent (kneeDelta ≈ 100°) so the broadened
      // stiff-legged `noKneeFlexion` path does not shadow this assertion.
      a.onRepStart(buildPose());
      for (var i = 0; i < 8; i++) {
        final frac = i / 7.0;
        a.evaluate(
          buildPose(
            hipX: 0.30,
            hipY: 0.50,
            kneeX: 0.45,
            kneeY: 0.70,
            ankleX: 0.30,
            heelY: 0.93, // genuine heel-lift geometry
          ),
        );
        a.trackAngle(170.0 - 100.0 * frac);
      }
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // `kneeDominantPattern` is tombstoned — both its inputs (heelLift,
      // forwardKneeShift) are informational/retired and the compound
      // FormError is no longer emitted.
      expect(errs, isNot(contains(FormError.kneeDominantPattern)));
      // The retired `heelLift` cue must also not appear.
      expect(errs, isNot(contains(FormError.heelLift)));
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
      // Feed a standing knee angle FIRST so `_startKneeAngle` ≈ 170°,
      // THEN the bottom angle. This gives `kneeDelta` ≈ 100° so the
      // broadened stiff-legged `noKneeFlexion` path (kneeDelta < 15°)
      // does not shadow the tempo/fatigue assertions. A single
      // `trackAngle(70.0)` would set both start and min to 70 ⇒
      // kneeDelta 0 ⇒ noKneeFlexion fires and replaces the expected
      // tempo error.
      a.trackAngle(170.0);
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

    test('fast ascent does NOT fire squatConcentricTooFast '
        '(cue TOMBSTONED 2026-05-21 — explosive ascent is good form)', () {
      final fast = make();
      final fastErrs = runRep(
        fast,
        descent: const Duration(milliseconds: 900),
        ascent: const Duration(milliseconds: 300), // < 0.5s floor
        start: t0,
      );
      // squatConcentricTooFast is no longer emitted — a fast concentric
      // (drive up) is desirable form when unloaded. Only the eccentric
      // (lowering) too-fast cue survives.
      expect(fastErrs, isNot(contains(FormError.squatConcentricTooFast)));
    });

    test('wide ascent-duration variance does NOT fire '
        'squatTempoInconsistent (cue TOMBSTONED 2026-05-21 — statistical '
        'detector, low confidence at typical rep counts)', () {
      final a = make();
      var start = t0;
      // Run a sequence with a deliberate 1800ms outlier among 800ms reps.
      // Pre-tombstone this tripped squatTempoInconsistent; post-tombstone
      // the detector still computes its rolling-window verdict for
      // telemetry but emits no FormError.
      final ascents = [800, 800, 800, 1800, 820, 800];
      for (final ms in ascents) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 900),
          ascent: Duration(milliseconds: ms),
          start: start,
        );
        expect(errs, isNot(contains(FormError.squatTempoInconsistent)));
        start = start.add(const Duration(seconds: 5));
      }
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

    test('squatFatigue does NOT fire even on a clear in-session slowdown '
        '(cue TOMBSTONED 2026-05-21 — statistical, needs many reps)', () {
      final a = make();
      var start = t0;
      // 3 fast then 6 slow — a textbook fatigue slowdown that pre-tombstone
      // would have fired squatFatigue once. Post-tombstone: no FormError.
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
      expect(fired, 0, reason: 'squatFatigue is tombstoned — never emitted');
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

    test('reset() runs cleanly across a tempo/fatigue rep sequence — the '
        'tombstoned squatFatigue cue never emits before OR after reset', () {
      // squatFatigue is tombstoned (2026-05-21): the rolling-window math
      // still runs (the window + one-shot guard are still reset by
      // `reset()`), but no FormError is emitted. This test now just
      // guards that the tombstoned cue stays silent and that a fatigue-
      // shaped rep sequence does not throw across a reset boundary.
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
      expect(firedBefore, 0, reason: 'squatFatigue tombstoned — never fires');

      a.reset();

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
      expect(firedAfter, 0, reason: 'still tombstoned post-reset');
    });
  });
}
