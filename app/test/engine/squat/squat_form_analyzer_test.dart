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

  group('SquatFormAnalyzer — excessiveForwardLean detection', () {
    test('upright pose does NOT fire excessiveForwardLean', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Hip directly under shoulder → 0° lean.
      final pose = buildPose(shoulderX: 0.30, hipX: 0.30);
      expect(a.evaluate(pose), isNot(contains(FormError.excessiveForwardLean)));
    });

    test('strong forward lean fires excessiveForwardLean', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Shoulder at x=0.30, y=0.20; hip at x=0.70, y=0.50.
      // dx=+0.40, dy=0.30 → atan2 ≈ 53° forward (well above 45° BW threshold).
      final pose = buildPose(
        shoulderX: 0.30,
        shoulderY: 0.20,
        hipX: 0.70,
        hipY: 0.50,
      );
      expect(a.evaluate(pose), contains(FormError.excessiveForwardLean));
    });

    test(
      'backward lean does NOT fire excessiveForwardLean (signed formula)',
      () {
        final a = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        // Hip behind the shoulder along +x → signed lean is NEGATIVE.
        // Without the signed formula this would false-fire as `|atan2|`.
        final pose = buildPose(
          shoulderX: 0.70,
          shoulderY: 0.20,
          hipX: 0.30,
          hipY: 0.50,
        );
        expect(
          a.evaluate(pose),
          isNot(contains(FormError.excessiveForwardLean)),
          reason:
              'Backward lean (negative signed angle) must not trigger the cue.',
        );
      },
    );

    test('HBBS tolerates 47° lean (below 50° threshold)', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: false,
      );
      // dx=0.32, dy=0.30 → atan2 ≈ 46.8°
      final pose = buildPose(
        shoulderX: 0.30,
        shoulderY: 0.20,
        hipX: 0.62,
        hipY: 0.50,
      );
      expect(a.evaluate(pose), isNot(contains(FormError.excessiveForwardLean)));
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
      // Selector should pick LEFT (higher confidence) → fires lean.
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
      expect(a.evaluate(pose), contains(FormError.excessiveForwardLean));
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
        a.trackAngle(85.0); // dipped below 90°
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
      // dx=0.50, dy=0.30 → atan2 ≈ 59° (above 45° BW threshold).
      final leanedPose = buildPose(
        shoulderX: 0.20,
        shoulderY: 0.20,
        hipX: 0.70,
        hipY: 0.50,
      );
      for (var i = 0; i < 5; i++) {
        a.evaluate(leanedPose);
        a.trackAngle(85.0);
      }
      a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      // Hand-computed expected value:
      //   atan2(0.50, 0.30) ≈ 59.04° (forward lean)
      //   severity = (59.04 − 45) / 30 ≈ 0.468
      //   deduction = severity × 0.20 ≈ 0.0936
      //   score = 1.0 × (1 − 0.0936) ≈ 0.906
      // The tight `closeTo` pins the formula — a regression that flipped the
      // formula to a flat 0.20 deduction (score 0.80) would fail this test.
      expect(a.lastRepQuality, closeTo(0.906, 0.01));
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
      a.trackAngle(85.0);
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
      a.trackAngle(120.0); // never reached effective bottom (90°)
      final errs = a.consumeCompletionErrorsWithDepth(kSquatBottomAngle);
      expect(errs, contains(FormError.squatDepth));
    });

    test('deep rep does NOT emit squatDepth at commit', () {
      final a = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      a.onRepStart(buildPose());
      a.trackAngle(80.0); // well below 90°
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
      a.trackAngle(85.0); // a deep rep so depth_factor doesn't deduct
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
      a.trackAngle(85.0);
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
}
