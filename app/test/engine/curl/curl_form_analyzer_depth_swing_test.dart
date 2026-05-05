/// Integration tests for the dual-layer depth-swing defense in
/// [CurlFormAnalyzer].
///
/// Layer 1 — Arm-Over-Torso Occlusion Gate (prevention):
///   When the curling arm sits inside the torso bounding box, the sway
///   detector is skipped entirely so its baseline cannot be poisoned by
///   drifting torso landmarks.
///
/// Layer 2 — Head Stability Corroborator (verification / veto):
///   When the sway detector fires but the head shows no corresponding
///   motion, the warning is suppressed as occlusion artifact.
///
/// These tests assert end-to-end behavior of the analyzer with both
/// layers active. The corroborator's standalone behavior is covered in
/// `head_stability_corroborator_test.dart`; here we validate that the
/// integration into `evaluate()` produces the right [FormError]s.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_form_analyzer.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a front-view pose with full landmark set including head + arms.
///
/// All coordinates normalized [0, 1]. The defense layers care about:
///   - shoulder/hip width and area (torso shape) — drives the sway detector
///   - nose.y and inter-ear distance — drives the head corroborator
///   - wrist/elbow position relative to torso bounding box — drives the
///     occlusion gate
///
/// Defaults represent a person standing neutrally facing the camera with
/// arms hanging *outside* the torso (so the occlusion gate is OFF unless
/// caller moves the wrist/elbow inside).
PoseResult buildPose({
  double shoulderScale = 1.0,
  double hipScale = 1.0,
  double noseY = 0.18,
  double earSpread = 0.04,
  // Arm position — defaults place wrists/elbows *outside* the torso box.
  double leftWristX = 0.30,
  double leftWristY = 0.65,
  double leftElbowX = 0.32,
  double leftElbowY = 0.50,
  double rightWristX = 0.70,
  double rightWristY = 0.65,
  double rightElbowX = 0.68,
  double rightElbowY = 0.50,
  // Visibility — drop head visibility to test fail-open.
  double headVisibility = 0.95,
  bool includeNose = true,
}) {
  PoseLandmark lm(int t, double x, double y, double conf) =>
      PoseLandmark(type: t, x: x, y: y, confidence: conf);

  const cx = 0.5;
  const cyShoulder = 0.30;
  const cyHip = 0.70;
  final shoulderHalf = 0.10 * shoulderScale;
  final hipHalf = 0.07 * hipScale;

  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      // Head
      if (includeNose) lm(LM.nose, cx, noseY, headVisibility),
      lm(LM.leftEar, cx - earSpread, noseY, headVisibility),
      lm(LM.rightEar, cx + earSpread, noseY, headVisibility),
      // Torso — both shoulders and hips visible at high confidence.
      lm(LM.leftShoulder, cx - shoulderHalf, cyShoulder, 0.95),
      lm(LM.rightShoulder, cx + shoulderHalf, cyShoulder, 0.95),
      lm(LM.leftHip, cx - hipHalf, cyHip, 0.95),
      lm(LM.rightHip, cx + hipHalf, cyHip, 0.95),
      // Arms
      lm(LM.leftElbow, leftElbowX, leftElbowY, 0.9),
      lm(LM.leftWrist, leftWristX, leftWristY, 0.9),
      lm(LM.rightElbow, rightElbowX, rightElbowY, 0.9),
      lm(LM.rightWrist, rightWristX, rightWristY, 0.9),
    ],
  );
}

/// Drive enough warm-up frames to satisfy both detectors' baseline windows.
/// The sway detector uses kSagittalBaselineMinFrames = 30; the head
/// corroborator uses kHeadBaselineMinFrames = 30; both warm in parallel.
DateTime warmUp(
  CurlFormAnalyzer a,
  DateTime t0, {
  PoseResult Function(int i)? poseFn,
}) {
  final fn = poseFn ?? (i) => buildPose();
  // Run a few extra frames beyond the larger of the two baselines.
  final n =
      (kSagittalBaselineMinFrames > kHeadBaselineMinFrames
          ? kSagittalBaselineMinFrames
          : kHeadBaselineMinFrames) +
      5;
  for (var i = 0; i < n; i++) {
    a.evaluate(fn(i), now: t0.add(Duration(milliseconds: 33 * i)));
  }
  return t0.add(Duration(milliseconds: 33 * n));
}

void main() {
  group('CurlFormAnalyzer dual-layer depth-swing defense', () {
    late CurlFormAnalyzer a;

    setUp(() {
      a = CurlFormAnalyzer();
      a.setView(CurlCameraView.front);
    });

    test(
      'Layer 2 vetoes depthSwing when head is stationary (artifact path)',
      () {
        final t0 = DateTime(2026);
        // Warm up both detectors with stationary baseline.
        final tNext = warmUp(a, t0);

        // Start a rep so depthSwing emission is enabled.
        a.onRepStart(buildPose());

        // Drive a sway-detector trip (shoulders proportionally larger than
        // hips — the "forward sway" signature) WITHOUT moving the head.
        // Real sagittal sway would translate the nose; this synthetic
        // motion mimics the arm-occlusion artifact (torso shape changes,
        // head is stationary).
        var sawDepthSwing = false;
        for (var i = 0; i < 60; i++) {
          final errs = a.evaluate(
            buildPose(
              shoulderScale: 1.0 + 0.012 * (i + 1),
              hipScale: 1.0,
              // Head perfectly fixed throughout.
              noseY: 0.18,
              earSpread: 0.04,
            ),
            now: tNext.add(Duration(milliseconds: 33 * i)),
          );
          if (errs.contains(FormError.depthSwing)) sawDepthSwing = true;
        }
        expect(
          sawDepthSwing,
          isFalse,
          reason:
              'Head was stationary throughout; corroborator should veto the '
              'sway detector\'s verdict (occlusion artifact).',
        );
      },
    );

    test(
      'Layer 2 does NOT veto when head moves with the spine (real sway)',
      () {
        final t0 = DateTime(2026);
        final tNext = warmUp(a, t0);
        a.onRepStart(buildPose());

        // Real sagittal sway: shoulders grow AND head dips downward.
        // Both signals corroborate, veto must NOT fire.
        var sawDepthSwing = false;
        for (var i = 0; i < 60; i++) {
          final errs = a.evaluate(
            buildPose(
              shoulderScale: 1.0 + 0.012 * (i + 1),
              hipScale: 1.0,
              // Head dips along with the lean — total 5% downward shift.
              noseY: 0.18 + 0.05 * ((i + 1) / 60),
              earSpread: 0.04 + 0.005 * ((i + 1) / 60),
            ),
            now: tNext.add(Duration(milliseconds: 33 * i)),
          );
          if (errs.contains(FormError.depthSwing)) sawDepthSwing = true;
        }
        expect(
          sawDepthSwing,
          isTrue,
          reason:
              'Head moved in sympathy with detected sway — the corroborator '
              'should NOT veto, depthSwing must fire.',
        );
      },
    );

    test(
      'fail-open: missing head landmarks → veto disabled, warning fires',
      () {
        final t0 = DateTime(2026);
        // Warm up with normal frames so the sway detector has a baseline.
        // The head corroborator never gets a clean head-landmark frame
        // because we set headVisibility low for warm-up too.
        final tNext = warmUp(
          a,
          t0,
          poseFn: (i) => buildPose(headVisibility: 0.2),
        );
        a.onRepStart(buildPose(headVisibility: 0.2));

        var sawDepthSwing = false;
        for (var i = 0; i < 60; i++) {
          final errs = a.evaluate(
            buildPose(
              shoulderScale: 1.0 + 0.012 * (i + 1),
              hipScale: 1.0,
              headVisibility:
                  0.2, // below kHeadCorroborationMinVisibility = 0.6
            ),
            now: tNext.add(Duration(milliseconds: 33 * i)),
          );
          if (errs.contains(FormError.depthSwing)) sawDepthSwing = true;
        }
        expect(
          sawDepthSwing,
          isTrue,
          reason:
              'Head landmarks below visibility gate → fail-open contract '
              'requires the analyzer to NOT veto and to emit depthSwing.',
        );
      },
    );

    test('Layer 1: arm-over-torso skips sway detector entirely', () {
      // The sway detector only emits non-neutral after baseline closes.
      // If we warm up entirely under occlusion, the detector should never
      // see a single frame and `baselineReady` (proxied via inability to
      // emit depthSwing even under extreme stimulus) stays false.
      final t0 = DateTime(2026);

      // 100 warm-up frames where the LEFT wrist sits inside the torso box.
      // Torso default box: x ∈ [0.40, 0.60], y ∈ [0.30, 0.70].
      // Place wrist at (0.50, 0.55) — squarely inside.
      for (var i = 0; i < 100; i++) {
        a.evaluate(
          buildPose(leftWristX: 0.50, leftWristY: 0.55),
          now: t0.add(Duration(milliseconds: 33 * i)),
        );
      }

      a.onRepStart(buildPose(leftWristX: 0.50, leftWristY: 0.55));

      // Now drive an extreme sway-shaped stimulus, still occluded.
      // Without Layer 1, this would trip the sway detector after baseline.
      // With Layer 1, the detector never advances → no depthSwing.
      var sawDepthSwing = false;
      for (var i = 0; i < 60; i++) {
        final errs = a.evaluate(
          buildPose(
            shoulderScale: 1.0 + 0.05 * (i + 1),
            hipScale: 1.0,
            leftWristX: 0.50,
            leftWristY: 0.55,
          ),
          now: t0.add(Duration(milliseconds: 33 * (100 + i))),
        );
        if (errs.contains(FormError.depthSwing)) sawDepthSwing = true;
      }
      expect(
        sawDepthSwing,
        isFalse,
        reason:
            'Layer 1 should have skipped every frame — sway detector never '
            'received input, so depthSwing cannot be emitted.',
      );
    });

    test('lifecycle: setView() to a new view resets corroborator', () {
      final t0 = DateTime(2026);
      warmUp(a, t0);

      // Switch to side view and back — the corroborator's reset() must
      // fire. After the switch, a new warm-up is required before any
      // verdict (validated indirectly: depthSwing is front-view-only and
      // setView triggers reset on view change).
      a.setView(CurlCameraView.sideLeft);
      a.setView(CurlCameraView.front);

      // First few frames after re-entering front view should be warm-up;
      // a sway-shaped stimulus must NOT trip immediately because the
      // corroborator's baseline is empty (fail-open path keeps it silent
      // until both detectors are armed).
      a.onRepStart(buildPose());
      var earlySawDepthSwing = false;
      for (var i = 0; i < 5; i++) {
        final errs = a.evaluate(
          buildPose(shoulderScale: 1.5, hipScale: 1.0),
          now: t0.add(Duration(seconds: 10, milliseconds: 33 * i)),
        );
        if (errs.contains(FormError.depthSwing)) earlySawDepthSwing = true;
      }
      expect(
        earlySawDepthSwing,
        isFalse,
        reason:
            'Both detectors\' baselines were reset on the view change — no '
            'verdict should issue during the cold-start window.',
      );
    });

    test('lifecycle: reset() clears both detectors', () {
      final t0 = DateTime(2026);
      warmUp(a, t0);
      a.reset();

      // After reset, the corroborator's baselineReady is false → fail-open
      // → no veto possible. But the sway detector is also reset, so it
      // cannot emit. End-to-end: a fresh stimulus produces no depthSwing.
      a.setView(CurlCameraView.front);
      a.onRepStart(buildPose());
      var sawDepthSwing = false;
      for (var i = 0; i < 5; i++) {
        final errs = a.evaluate(
          buildPose(shoulderScale: 1.5, hipScale: 1.0),
          now: t0.add(Duration(seconds: 20, milliseconds: 33 * i)),
        );
        if (errs.contains(FormError.depthSwing)) sawDepthSwing = true;
      }
      expect(sawDepthSwing, isFalse);
    });
  });
}
