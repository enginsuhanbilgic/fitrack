/// Unit tests for the 2026-05-21 squat audit changes.
///
/// Covers (one test per change so a regression points at the right diff):
///   1. `_signedLeanDeg` sign normalization — mirror-pose invariance.
///   2. `_kneeShiftRatio` direction-agnostic magnitude — mirror-pose invariance.
///   3. `noKneeFlexion` broadened with stiff-legged OR clause.
///   4. BOTTOM → IDLE timeout after `kSquatBottomMaxHoldMs`.
///   5. `onNextSet` clears the strategy's per-rep state — the contract
///      `RepCounter._resetToIdle` now relies on (watchdog itself uses
///      DateTime.now() so end-to-end watchdog timing isn't unit-testable
///      without a clock seam; the strategy-side contract is what changed).
///   6. `thresholdsProvider` throwing falls back to the construction-time
///      tuple instead of crashing the pipeline.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/engine/squat/squat_form_analyzer.dart';
import 'package:fitrack/engine/squat/squat_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a synthetic side-view pose. `leftConfidence`/`rightConfidence`
/// control which side the camera-side picker chooses. To test mirror-pose
/// invariance, swap which side has high confidence and mirror every X
/// coordinate around `x = 0.5`.
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
  group('squat audit 2026-05-21 — sign-normalization', () {
    test('forward-lean sign is positive for both right-facing and left-facing '
        'camera views (was inverted on left-facing pre-fix)', () {
      // Right-facing view (toes pointing toward +x): heel sits BEHIND the
      // hip in screen-x (heel.x < hip.x), so heel→hip points in +x and
      // forwardSign = +1. A forward lean shifts hip ahead of shoulder
      // in +x, producing dx > 0 ⇒ positive lean.
      final rightFacingForward = buildPose(
        shoulderX: 0.32,
        shoulderY: 0.20,
        hipX: 0.42,
        hipY: 0.50,
        heelX: 0.30, // BEHIND hip along toes direction
      );
      // Left-facing view: mirror every X across 0.5 and flip confidences
      // so the picker chooses the right (camera-near) side. Heel now sits
      // at higher x than hip ⇒ heel→hip points in −x ⇒ forwardSign = −1.
      // The raw dx is also negative (hip left of shoulder), and the two
      // negatives cancel ⇒ positive lean.
      final leftFacingForward = buildPose(
        shoulderX: 1.0 - 0.32,
        shoulderY: 0.20,
        hipX: 1.0 - 0.42,
        hipY: 0.50,
        heelX: 1.0 - 0.30,
        leftConfidence: 0.30,
        rightConfidence: 0.95,
      );

      final aRight = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      aRight.evaluate(rightFacingForward);
      final aLeft = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      aLeft.evaluate(leftFacingForward);

      final rightLean = aRight.currentSignedLeanDeg;
      final leftLean = aLeft.currentSignedLeanDeg;
      expect(rightLean, isNotNull);
      expect(leftLean, isNotNull);
      // Both should report POSITIVE forward lean post-fix. Pre-fix, the
      // left-facing analyzer returned a negative value (forward seen
      // as backward).
      expect(rightLean!, greaterThan(0));
      expect(leftLean!, greaterThan(0));
      // Magnitudes should match within floating-point tolerance.
      expect((rightLean - leftLean).abs(), lessThan(0.1));
    });

    test('knee-shift ratio is non-zero and identical for mirrored knee-forward '
        'poses (was silently zero for left-facing users pre-fix)', () {
      // Right-facing: knee ahead of ankle in +x.
      final rightFacing = buildPose(kneeX: 0.40, ankleX: 0.30, hipX: 0.30);
      // Left-facing: knee ahead of ankle in −x (mirror across 0.5).
      final leftFacing = buildPose(
        kneeX: 1.0 - 0.40,
        ankleX: 1.0 - 0.30,
        hipX: 1.0 - 0.30,
        leftConfidence: 0.30,
        rightConfidence: 0.95,
      );

      final aRight = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      aRight.evaluate(rightFacing);
      aRight.consumeCompletionErrorsWithDepth(80.0);

      final aLeft = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      aLeft.evaluate(leftFacing);
      aLeft.consumeCompletionErrorsWithDepth(80.0);

      expect(aRight.lastRepKneeShiftRatio, isNotNull);
      expect(aLeft.lastRepKneeShiftRatio, isNotNull);
      // Pre-fix the left side would have been zero (clamped). Post-fix
      // both are positive and equal in magnitude.
      expect(aRight.lastRepKneeShiftRatio!, greaterThan(0));
      expect(aLeft.lastRepKneeShiftRatio!, greaterThan(0));
      expect(
        (aRight.lastRepKneeShiftRatio! - aLeft.lastRepKneeShiftRatio!).abs(),
        lessThan(0.01),
      );
    });
  });

  group('squat audit 2026-05-21 — noKneeFlexion broadened', () {
    test('stiff-legged miss fires noKneeFlexion even with no lean '
        '(closes the pre-2026-05-21 conjunction hole)', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Simulate a rep where the user barely bent their knees (10°
      // delta) AND barely leaned (no lean evaluation — so _maxLeanDeg
      // stays null). Pre-broadening this fell through every gate.
      analyzer.onRepStart(buildPose());
      analyzer.trackAngle(175.0); // descent start
      analyzer.trackAngle(165.0); // bottom — 10° delta total
      final errors = analyzer.consumeCompletionErrorsWithDepth(80.0);
      expect(errors, contains(FormError.noKneeFlexion));
    });

    test(
      'normal squat with healthy knee delta does NOT fire noKneeFlexion',
      () {
        final analyzer = SquatFormAnalyzer(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        analyzer.onRepStart(buildPose());
        analyzer.trackAngle(175.0); // start
        analyzer.trackAngle(75.0); // bottom — 100° delta
        final errors = analyzer.consumeCompletionErrorsWithDepth(80.0);
        expect(errors.contains(FormError.noKneeFlexion), isFalse);
      },
    );
  });

  group('squat audit 2026-05-21 — BOTTOM timeout', () {
    test('holding BOTTOM longer than kSquatBottomMaxHoldMs returns to IDLE '
        'without committing a rep', () {
      final strategy = SquatStrategy(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final t0 = DateTime(2026, 5, 21, 10, 0, 0);
      // Drive IDLE → DESCENDING. The High-anchored startAngle is 166.4°,
      // so a smoothedAngle below that is required.
      var out = strategy.tick(
        StrategyFrameInput(
          pose: buildPose(),
          smoothedAngle: 160.0,
          state: RepState.idle,
          repIndexInSet: 0,
          now: t0,
        ),
      );
      expect(out.nextState, RepState.descending);
      // DESCENDING → BOTTOM (smoothed < effectiveBottomAngle = 80°).
      out = strategy.tick(
        StrategyFrameInput(
          pose: buildPose(),
          smoothedAngle: 70.0,
          state: RepState.descending,
          repIndexInSet: 0,
          now: t0.add(const Duration(milliseconds: 500)),
        ),
      );
      expect(out.nextState, RepState.bottom);
      // Hold BOTTOM past the timeout.
      out = strategy.tick(
        StrategyFrameInput(
          pose: buildPose(),
          smoothedAngle: 70.0,
          state: RepState.bottom,
          repIndexInSet: 0,
          now: t0.add(Duration(milliseconds: 500 + kSquatBottomMaxHoldMs + 1)),
        ),
      );
      expect(out.nextState, RepState.idle);
      expect(out.repCommitted, isFalse);
    });
  });

  group('squat audit 2026-05-21 — strategy reset propagation', () {
    test(
      'onNextSet clears per-rep state (the contract _resetToIdle now relies on)',
      () {
        final strategy = SquatStrategy(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
        );
        final t0 = DateTime(2026, 5, 21, 10, 0, 0);
        // Drive IDLE → DESCENDING → BOTTOM so per-rep state is non-trivial.
        strategy.tick(
          StrategyFrameInput(
            pose: buildPose(),
            smoothedAngle: 160.0,
            state: RepState.idle,
            repIndexInSet: 0,
            now: t0,
          ),
        );
        strategy.tick(
          StrategyFrameInput(
            pose: buildPose(),
            smoothedAngle: 70.0,
            state: RepState.descending,
            repIndexInSet: 0,
            now: t0.add(const Duration(milliseconds: 50)),
          ),
        );
        // Force per-rep reset (what RepCounter._resetToIdle now does).
        strategy.onNextSet();
        // A fresh IDLE → DESCENDING tick must transition without inheriting
        // stale state — proven by a clean IDLE → DESCENDING that uses the
        // current frame's threshold gate.
        final out = strategy.tick(
          StrategyFrameInput(
            pose: buildPose(),
            smoothedAngle: 160.0,
            state: RepState.idle,
            repIndexInSet: 0,
            now: t0.add(const Duration(seconds: 6)),
          ),
        );
        expect(out.nextState, RepState.descending);
        expect(out.repCommitted, isFalse);
      },
    );
  });

  group('squat audit 2026-05-21 — thresholdsProvider exception safety', () {
    test(
      'a thrown thresholdsProvider falls back to the construction-time tuple '
      'without crashing the FSM',
      () {
        final fallback = SquatRomDefaults.defaults;
        final strategy = SquatStrategy(
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          romThresholds: fallback,
          thresholdsProvider: (_) => throw StateError('boom'),
        );
        // Should not throw; should transition to DESCENDING using the
        // fallback tuple's startAngle.
        expect(
          () => strategy.tick(
            StrategyFrameInput(
              pose: buildPose(),
              smoothedAngle: fallback.startAngle - 1.0,
              state: RepState.idle,
              repIndexInSet: 0,
              now: DateTime(2026, 5, 21),
            ),
          ),
          returnsNormally,
        );
      },
    );
  });
}
