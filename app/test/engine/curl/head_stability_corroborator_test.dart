/// Unit tests for [HeadStabilityCorroborator].
///
/// All tests drive the corroborator with synthetic [PoseResult] frames so we
/// can control nose / ear / shoulder / hip geometry exactly and assert on
/// the z-scored signals without any camera or ML Kit involvement.
///
/// Coverage:
///   - reset() clears all state
///   - warm-up returns landmarksAvailable=true, baselineReady=false, no z
///   - stationary head past warm-up → both z-scores ≈ 0
///   - vertical bob → verticalZ exceeds threshold
///   - lean-in (ears spread apart) → scaleZ exceeds threshold
///   - missing nose / ear → landmarksAvailable=false (fail-open contract)
///   - σ drift cap holds over a long stationary stretch
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/curl/head_stability_corroborator.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a front-view pose with parametrized head and torso geometry.
///
/// All coordinates normalized [0, 1]. The corroborator needs nose, both
/// ears, and all four torso landmarks (for the torso-length normalization
/// captured at baseline close).
///
/// [noseY] — vertical position of the nose. Drives `verticalZ`.
/// [earSpread] — half-distance from face center to each ear. Drives `scaleZ`.
/// [includeNose] / [includeLeftEar] / [includeRightEar] — set false to
///   simulate landmark visibility dropping below the gate.
/// [headVisibility] — confidence assigned to nose + ears (separate from
///   torso landmarks so we can drop one without dropping the other).
PoseResult buildPose({
  double noseY = 0.20,
  double earSpread = 0.04,
  bool includeNose = true,
  bool includeLeftEar = true,
  bool includeRightEar = true,
  double headVisibility = 0.9,
  double torsoVisibility = 0.9,
}) {
  PoseLandmark lm(int t, double x, double y, double conf) =>
      PoseLandmark(type: t, x: x, y: y, confidence: conf);

  const cx = 0.5;
  // Head sits well above the shoulders (smaller y in image coords).
  // Ears flank the nose horizontally at the same y.
  final landmarks = <PoseLandmark>[
    if (includeNose) lm(LM.nose, cx, noseY, headVisibility),
    if (includeLeftEar) lm(LM.leftEar, cx - earSpread, noseY, headVisibility),
    if (includeRightEar) lm(LM.rightEar, cx + earSpread, noseY, headVisibility),
    // Torso — fixed for all tests except where torso visibility matters.
    lm(LM.leftShoulder, cx - 0.10, 0.30, torsoVisibility),
    lm(LM.rightShoulder, cx + 0.10, 0.30, torsoVisibility),
    lm(LM.leftHip, cx - 0.07, 0.70, torsoVisibility),
    lm(LM.rightHip, cx + 0.07, 0.70, torsoVisibility),
  ];

  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: landmarks,
  );
}

/// Drive the corroborator through a full baseline window with stationary
/// head. Returns the t value at which the next frame would be timestamped.
DateTime fillBaseline(
  HeadStabilityCorroborator c,
  DateTime t0, {
  PoseResult Function(int i)? poseFn,
}) {
  final fn = poseFn ?? (i) => buildPose();
  for (var i = 0; i < kHeadBaselineMinFrames; i++) {
    c.update(
      pose: fn(i),
      now: t0.add(Duration(milliseconds: 33 * i)),
      allowBaseline: true,
    );
  }
  return t0.add(Duration(milliseconds: 33 * kHeadBaselineMinFrames));
}

void main() {
  group('HeadStabilityCorroborator', () {
    test('warm-up returns no z-scores and not-ready', () {
      final c = HeadStabilityCorroborator();
      final t0 = DateTime(2026);
      for (var i = 0; i < kHeadBaselineMinFrames - 1; i++) {
        final r = c.update(
          pose: buildPose(),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
        expect(r.baselineReady, isFalse);
        expect(r.landmarksAvailable, isTrue);
        expect(r.verticalZ, isNull);
        expect(r.scaleZ, isNull);
      }
    });

    test('reset() clears all state — baseline must re-warm', () {
      final c = HeadStabilityCorroborator();
      final t0 = DateTime(2026);
      fillBaseline(c, t0);
      expect(c.baselineReady, isTrue);

      c.reset();
      expect(c.baselineReady, isFalse);

      // First post-reset frame should still be in warm-up.
      final r = c.update(
        pose: buildPose(),
        now: t0.add(const Duration(seconds: 5)),
        allowBaseline: true,
      );
      expect(r.baselineReady, isFalse);
    });

    test(
      'stationary head past baseline yields ~0 z-scores (no veto trigger)',
      () {
        final c = HeadStabilityCorroborator();
        final t0 = DateTime(2026);
        // Tiny jitter so σ > 0 floor (avoid divide-by-near-zero amplification).
        final tNext = fillBaseline(
          c,
          t0,
          poseFn: (i) => buildPose(
            noseY: 0.20 + (i.isEven ? 0.0 : 0.0005),
            earSpread: 0.04 + (i.isEven ? 0.0 : 0.00005),
          ),
        );
        expect(c.baselineReady, isTrue);

        var maxV = 0.0;
        var maxS = 0.0;
        for (var i = 0; i < 30; i++) {
          final r = c.update(
            pose: buildPose(noseY: 0.20, earSpread: 0.04),
            now: tNext.add(Duration(milliseconds: 33 * i)),
            allowBaseline: false,
          );
          if (r.verticalZ != null && r.verticalZ!.abs() > maxV) {
            maxV = r.verticalZ!.abs();
          }
          if (r.scaleZ != null && r.scaleZ!.abs() > maxS) {
            maxS = r.scaleZ!.abs();
          }
        }
        // Both signals should be small enough that the analyzer's veto rule
        // (weighted sum < kHeadCorroborationMinZ = 0.6) suppresses the warning.
        final composite = kHeadVerticalWeight * maxV + kHeadScaleWeight * maxS;
        expect(composite, lessThan(kHeadCorroborationMinZ));
      },
    );

    test(
      'vertical bob (nose.y oscillates) raises verticalZ above threshold',
      () {
        final c = HeadStabilityCorroborator();
        final t0 = DateTime(2026);
        final tNext = fillBaseline(c, t0);
        expect(c.baselineReady, isTrue);

        // Sustained vertical translation — head moves down 5% of image then
        // stays. This is the signature of a real forward lean (head dips
        // toward camera lower frame).
        var maxAbsV = 0.0;
        for (var i = 0; i < 60; i++) {
          final r = c.update(
            pose: buildPose(noseY: 0.20 + 0.05),
            now: tNext.add(Duration(milliseconds: 33 * i)),
            allowBaseline: false,
          );
          if (r.verticalZ != null && r.verticalZ!.abs() > maxAbsV) {
            maxAbsV = r.verticalZ!.abs();
          }
        }
        // Expect verticalZ to swing well past the corroboration threshold.
        expect(maxAbsV, greaterThan(kHeadCorroborationMinZ));
      },
    );

    test('ears spreading apart (lean-in scale signal) raises scaleZ', () {
      final c = HeadStabilityCorroborator();
      final t0 = DateTime(2026);
      final tNext = fillBaseline(c, t0);
      expect(c.baselineReady, isTrue);

      // 25% growth in inter-ear distance — mimics 1/Z scaling under a real
      // forward lean toward the camera.
      var maxAbsS = 0.0;
      for (var i = 0; i < 60; i++) {
        final r = c.update(
          pose: buildPose(noseY: 0.20, earSpread: 0.05),
          now: tNext.add(Duration(milliseconds: 33 * i)),
          allowBaseline: false,
        );
        if (r.scaleZ != null && r.scaleZ!.abs() > maxAbsS) {
          maxAbsS = r.scaleZ!.abs();
        }
      }
      expect(maxAbsS, greaterThan(kHeadCorroborationMinZ));
    });

    test('missing nose → landmarksAvailable=false, no state advance', () {
      final c = HeadStabilityCorroborator();
      final t0 = DateTime(2026);

      // Drive 10 frames with nose missing — these must NOT count toward the
      // baseline window. Then drive a full baseline window with nose
      // present and assert the corroborator only became ready after the
      // *good* frames filled the window.
      for (var i = 0; i < 10; i++) {
        final r = c.update(
          pose: buildPose(includeNose: false),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
        expect(r.landmarksAvailable, isFalse);
        expect(r.baselineReady, isFalse);
      }

      var becameReadyAt = -1;
      for (var i = 0; i < kHeadBaselineMinFrames; i++) {
        final r = c.update(
          pose: buildPose(),
          now: t0.add(Duration(milliseconds: 33 * (10 + i))),
          allowBaseline: true,
        );
        if (r.baselineReady && becameReadyAt < 0) becameReadyAt = i;
      }
      // Should become ready exactly at the kHeadBaselineMinFrames-th good
      // frame, NOT earlier (which would mean missing-nose frames polluted
      // the baseline window).
      expect(becameReadyAt, kHeadBaselineMinFrames - 1);
    });

    test('missing ear → fail-open (landmarksAvailable=false)', () {
      final c = HeadStabilityCorroborator();
      final r = c.update(
        pose: buildPose(includeRightEar: false),
        now: DateTime(2026),
        allowBaseline: true,
      );
      expect(r.landmarksAvailable, isFalse);
    });

    test('low head visibility → fail-open (landmarksAvailable=false)', () {
      final c = HeadStabilityCorroborator();
      final r = c.update(
        // Below kHeadCorroborationMinVisibility = 0.6.
        pose: buildPose(headVisibility: 0.3),
        now: DateTime(2026),
        allowBaseline: true,
      );
      expect(r.landmarksAvailable, isFalse);
    });

    test('σ drift cap: long stationary stretch keeps z-scores responsive', () {
      // Indirect test of the drift cap: if σ were allowed to grow without
      // bound, an eventual real motion would not produce a high z-score.
      // After 200 frames of slow drift, a sudden spike must still register.
      final c = HeadStabilityCorroborator();
      final t0 = DateTime(2026);
      final tBase = fillBaseline(c, t0);

      // 200 frames of very slow noseY drift (well within the bobble noise
      // budget). σ adapts but is hard-capped at kHeadSigmaDriftCap × init.
      for (var i = 0; i < 200; i++) {
        c.update(
          pose: buildPose(noseY: 0.20 + 0.0001 * i),
          now: tBase.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }

      // Now jolt the head down by 5%. Even with adapted σ, this must
      // produce a corroborating z-score above the threshold.
      var maxAbsV = 0.0;
      final tJolt = tBase.add(const Duration(milliseconds: 33 * 200));
      for (var i = 0; i < 30; i++) {
        final r = c.update(
          pose: buildPose(noseY: 0.20 + 0.05),
          now: tJolt.add(Duration(milliseconds: 33 * i)),
          allowBaseline: false,
        );
        if (r.verticalZ != null && r.verticalZ!.abs() > maxAbsV) {
          maxAbsV = r.verticalZ!.abs();
        }
      }
      expect(maxAbsV, greaterThan(kHeadCorroborationMinZ));
    });
  });
}
