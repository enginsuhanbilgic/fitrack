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
        'camera views — squat geometry (shoulder ahead of hip = forward)', () {
      // Squat forward-lean geometry (confirmed by 2026-05-21 raw landmark
      // telemetry): the SHOULDER tilts forward over the toes while the
      // HIP drops back/down. So `shoulder.x − hip.x` (along the toes
      // direction) is positive on a forward-leaning squat.
      //
      // Right-facing view (toes toward +x): foot_index ahead of heel
      // (footX > heelX) ⇒ forwardSign = +1. Place shoulder at higher x
      // than hip to simulate the squat lean pattern.
      final rightFacingForward = buildPose(
        shoulderX: 0.42, // shoulder ahead of hip toward toes (+x)
        shoulderY: 0.20,
        hipX: 0.32,
        hipY: 0.50,
        heelX: 0.30,
        footX: 0.40, // ahead of heel along toes direction
      );
      // Left-facing view: mirror EVERY X across 0.5 (including footX so
      // the foot's anatomy mirrors too). Flip confidences so the picker
      // chooses the right (camera-near) side. foot_index now sits at
      // lower x than heel ⇒ forwardSign = −1. Shoulder is now LEFT of
      // hip on screen; raw dx = (shoulder − hip) is negative; multiplied
      // by −1 ⇒ positive lean.
      final leftFacingForward = buildPose(
        shoulderX: 1.0 - 0.42,
        shoulderY: 0.20,
        hipX: 1.0 - 0.32,
        hipY: 0.50,
        heelX: 1.0 - 0.30,
        footX: 1.0 - 0.40,
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

    test('forward-lean is positive on the literal 2026-05-21 BOTTOM frame '
        '(the regression that drove the comparison-direction swap)', () {
      // Frame from the 2026-05-21 03:55 session, rep 1 deepest BOTTOM,
      // left-side reading on a left-side-facing user. Pre-swap this
      // reported `signed_lean = -45°` (forward lean read as backward);
      // post-swap it must read positive.
      //
      // Source line (verbatim from the telemetry log):
      //   squat.foot_geom: fsm=bottom
      //     l_shoulder.x=0.442@1.00 l_hip.x=0.331@1.00
      //     l_heel.x=0.317@0.99 l_foot.x=0.373@0.98
      //     r_shoulder.x=0.482@1.00 r_hip.x=0.363@1.00
      //     r_heel.x=0.382@0.98 r_foot.x=0.460@0.97
      //
      // The user was leaning forward on every rep (verified physically).
      // foot_index.x (0.373) > heel.x (0.317) ⇒ forwardSign = +1.
      // shoulder.x (0.442) > hip.x (0.331) ⇒ raw dx > 0.
      // ⇒ atan2(positive, positive) ⇒ positive lean. ✓
      //
      // Pre-swap formula computed dx = hip.x − shoulder.x = −0.111 ⇒
      // negative lean, which is what the production log captured.
      PoseLandmark lm(int t, double x, double y, double c) =>
          PoseLandmark(type: t, x: x, y: y, confidence: c);
      final telemetryFrame = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: [
          // Y values approximated — only X is sign-load-bearing for this
          // test, and Y just needs to be non-degenerate (shoulder above
          // hip in screen-Y so dy > 0).
          lm(LM.leftShoulder, 0.442, 0.20, 1.00),
          lm(LM.leftHip, 0.331, 0.55, 1.00),
          lm(LM.leftKnee, 0.42, 0.70, 1.00),
          lm(LM.leftAnkle, 0.30, 0.95, 1.00),
          lm(LM.leftHeel, 0.317, 0.97, 0.99),
          lm(LM.leftFootIndex, 0.373, 0.97, 0.98),
          // Right-side: copies of left-side coords with slightly lower
          // confidence so the picker chooses left (mirrors the actual
          // session where left side was camera-near).
          lm(LM.rightShoulder, 0.482, 0.20, 1.00),
          lm(LM.rightHip, 0.363, 0.55, 1.00),
          lm(LM.rightKnee, 0.45, 0.70, 0.99),
          lm(LM.rightAnkle, 0.32, 0.95, 0.99),
          lm(LM.rightHeel, 0.382, 0.97, 0.98),
          lm(LM.rightFootIndex, 0.460, 0.97, 0.97),
        ],
      );
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      analyzer.evaluate(telemetryFrame);
      final lean = analyzer.currentSignedLeanDeg;
      expect(lean, isNotNull);
      // POSITIVE on the exact telemetry frame that previously produced
      // signed_lean = −45° in production. Locks the regression in.
      expect(lean!, greaterThan(0));
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

  group('squat audit 2026-05-21 — side-lock (flicker fix)', () {
    test('side is locked at onRepStart — mid-rep confidence flip does NOT '
        'change which side the analyzer reads from', () {
      // The pre-fix bug: `_pickCameraSide` ran per-frame inside
      // `evaluate()`. The 2026-05-21 debug session captured 6 reps where
      // `signed_lean` alternated sign rep-by-rep (−49, +44, −45, +49, +50,
      // −43) on a single user filming from one direction — the picker
      // flickered between left and right per frame, and the foot-anchored
      // sign correction then applied opposite forward directions on
      // consecutive samples within the same rep.
      //
      // Post-fix contract: `onRepStart` picks the side once from the
      // start snapshot, locks it for the rep, and the lock survives a
      // mid-rep confidence flip in `evaluate()`.
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Realistic ML Kit flicker: both sides above the confidence gate
      // (0.4), ranking just swaps frame-to-frame. Pre-fix, this flipped
      // the camera-side per frame and corrupted the signed-lean sign.
      //
      // Build a pose with the LEFT side ranked slightly higher than the
      // right — both well above the 0.4 confidence gate. Squat
      // forward-lean geometry: shoulder ahead of hip along toes (+x)
      // direction, foot_index ahead of heel.
      final repStartPose = buildPose(
        shoulderX: 0.42, // ahead of hip toward toes
        hipX: 0.32,
        heelX: 0.30,
        footX: 0.40,
        leftConfidence: 0.90,
        rightConfidence: 0.85,
      );
      analyzer.onRepStart(repStartPose);
      analyzer.evaluate(repStartPose);
      final leanAfterStart = analyzer.currentSignedLeanDeg;
      expect(leanAfterStart, isNotNull);
      expect(leanAfterStart!, greaterThan(0)); // forward lean ⇒ positive

      // Mid-rep flicker: rank reverses (right now slightly higher than
      // left). To prove the lock actually held, mirror the RIGHT-side
      // X-coordinates across 0.5 so the right side reads as a
      // legitimate forward lean too (mirrored anatomy). With the lock
      // holding to the LEFT side, the sign must stay positive — but
      // the sign would also stay positive if it flipped to right (both
      // are forward-leaning, mirrored). To make the lock observable
      // distinctly, give the right side a BACKWARD-leaning posture
      // (shoulder behind hip in the mirrored toes direction). If the
      // lock fails, the analyzer reads right and reports negative.
      PoseLandmark lm(int t, double x, double y, double c) =>
          PoseLandmark(type: t, x: x, y: y, confidence: c);
      final flickerPose = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: [
          // Left side: same forward-leaning coords (locked side reads here).
          lm(LM.leftShoulder, 0.42, 0.20, 0.85),
          lm(LM.leftHip, 0.32, 0.50, 0.85),
          lm(LM.leftKnee, 0.30, 0.70, 0.85),
          lm(LM.leftAnkle, 0.30, 0.95, 0.85),
          lm(LM.leftHeel, 0.30, 0.97, 0.85),
          lm(LM.leftFootIndex, 0.40, 0.97, 0.85),
          // Right side: mirrored across 0.5 AND with shoulder positioned
          // so that, if read, it would produce a NEGATIVE lean signal.
          // For the right-facing mirror, toes point toward −x. Forward
          // lean would need shoulder LESS than hip (more negative).
          // Place shoulder GREATER than hip to invert that ⇒ backward
          // lean if read. Higher confidence than left so the picker
          // would choose right if re-run.
          lm(LM.rightShoulder, 1 - 0.32, 0.20, 0.90),
          lm(LM.rightHip, 1 - 0.42, 0.50, 0.90),
          lm(LM.rightKnee, 1 - 0.30, 0.70, 0.90),
          lm(LM.rightAnkle, 1 - 0.30, 0.95, 0.90),
          lm(LM.rightHeel, 1 - 0.30, 0.97, 0.90),
          lm(LM.rightFootIndex, 1 - 0.40, 0.97, 0.90),
        ],
      );
      analyzer.evaluate(flickerPose);
      final leanAfterFlicker = analyzer.currentSignedLeanDeg;
      expect(leanAfterFlicker, isNotNull);
      // Lock held: sign unchanged, still positive.
      expect(leanAfterFlicker!, greaterThan(0));
    });

    test('side-lock releases at rep commit — next rep can pick a different '
        'side if confidence ranking actually changed', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      // Rep 1: left dominant.
      final leftPose = buildPose(leftConfidence: 0.95, rightConfidence: 0.30);
      analyzer.onRepStart(leftPose);
      analyzer.trackAngle(175.0);
      analyzer.trackAngle(75.0);
      analyzer.consumeCompletionErrorsWithDepth(80.0);
      // Lock is now released. Rep 2: right dominant.
      final rightPose = buildPose(leftConfidence: 0.30, rightConfidence: 0.95);
      analyzer.onRepStart(rightPose);
      analyzer.evaluate(rightPose);
      // The HUD should report a non-null lean — proves the new rep's
      // side-lock activated and `evaluate` is reading correctly.
      expect(analyzer.currentSignedLeanDeg, isNotNull);
    });
  });

  group('squat audit 2026-05-21 — knee-led min-hip-drop floor', () {
    test('knee-led detector abstains (ratio=0) when hip drop is below '
        'kSquatKneeLedMinHipDropNorm — kills the >9000 explosion', () {
      // The pre-fix bug: when the anchor frame caught the user nearly
      // stationary and the next sample one frame later still showed
      // virtually no hip drop, the `math.max(1e-6, hipDrop)` clamp
      // exploded the ratio. The 2026-05-21 debug session captured
      // `ratio=9931.405` and `ratio=7907.168` on real reps.
      //
      // Post-fix contract: when `hipDrop / legLen <
      // kSquatKneeLedMinHipDropNorm`, the detector silently writes
      // ratio=0 and does not fire.
      //
      // We simulate this by driving evaluate() with two frames at the
      // descent window's open/close: same hip.y (no drop), different
      // knee.x (some travel). Pre-fix this gave a huge ratio; post-fix
      // it gives 0.0.
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final t0 = DateTime(2026, 5, 21, 10, 0, 0);
      // Anchor frame.
      analyzer.onRepStart(buildPose());
      analyzer.evaluate(
        buildPose(
          hipX: 0.30,
          hipY: 0.50,
          kneeX: 0.30,
          kneeY: 0.70,
          ankleX: 0.30,
          ankleY: 0.95,
        ),
        now: t0,
      );
      // Closing frame, well past the 200ms window — hip Y unchanged
      // (no drop), knee X moved a lot.
      analyzer.evaluate(
        buildPose(
          hipX: 0.30,
          hipY: 0.50,
          kneeX: 0.45,
          kneeY: 0.70,
          ankleX: 0.30,
          ankleY: 0.95,
        ),
        now: t0.add(const Duration(milliseconds: 250)),
      );
      // Detector should have closed its window with ratio=0 (abstain).
      // Pre-fix this would have been thousands.
      expect(analyzer.lastRepKneeLedRatio, isNotNull);
      expect(analyzer.lastRepKneeLedRatio!, lessThan(0.1));
    });
  });

  group('squat audit 2026-05-21 — auto-detected long-femur lean boost', () {
    test('applyAutoDetectedLongFemurBoost widens leanWarnDeg by +5° when the '
        'manual toggle is OFF (the 2026-05-21 accurate-form-misfire fix)', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final before = analyzer.leanWarnDeg;
      analyzer.applyAutoDetectedLongFemurBoost();
      final after = analyzer.leanWarnDeg;
      // Should widen by exactly the long-femur boost constant.
      expect(after - before, closeTo(kSquatLongFemurLeanBoost, 1e-9));
    });

    test('applyAutoDetectedLongFemurBoost is a no-op when the manual toggle '
        'is ON (prevents double-stacking)', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: true,
      );
      final before = analyzer.leanWarnDeg;
      analyzer.applyAutoDetectedLongFemurBoost();
      final after = analyzer.leanWarnDeg;
      // Manual toggle already applied the boost at construction; the
      // auto path must NOT add another +5°.
      expect(after, before);
    });

    test('applyAutoDetectedLongFemurBoost is idempotent on repeated calls', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final before = analyzer.leanWarnDeg;
      analyzer.applyAutoDetectedLongFemurBoost();
      analyzer.applyAutoDetectedLongFemurBoost();
      analyzer.applyAutoDetectedLongFemurBoost();
      final after = analyzer.leanWarnDeg;
      // Still only +5° total no matter how many times the strategy
      // pings the analyzer (the IDLE tick can call it every frame).
      expect(after - before, closeTo(kSquatLongFemurLeanBoost, 1e-9));
    });

    test('reset() restores the construction-time lean threshold for a '
        'lifter without the manual toggle (so a fresh session re-evaluates '
        'long-femur from scratch)', () {
      final analyzer = SquatFormAnalyzer(
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
      );
      final initial = analyzer.leanWarnDeg;
      analyzer.applyAutoDetectedLongFemurBoost();
      expect(analyzer.leanWarnDeg, greaterThan(initial));
      analyzer.reset();
      expect(analyzer.leanWarnDeg, closeTo(initial, 1e-9));
    });
  });
}
