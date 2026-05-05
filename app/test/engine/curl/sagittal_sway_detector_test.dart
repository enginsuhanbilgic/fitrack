/// Unit tests for [SagittalSwayDetector].
///
/// All tests drive the detector with synthetic [PoseResult] frames so we
/// can control the geometry exactly and assert on the classified
/// direction without any camera or ML Kit involvement.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/curl/sagittal_sway_detector.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a front-view pose with parametrized perspective sway.
///
/// IMPORTANT: the sway detector's features are deliberately invariant
/// under uniform body scale (so camera distance cancels). Synthesizing a
/// "forward lean" therefore requires a *non-uniform* change — the upper
/// body must grow proportionally more than the lower body, mirroring
/// what happens under real pinhole projection when only the torso pitches
/// forward at the hip.
///
/// [shoulderScale] multiplies shoulder span; [hipScale] multiplies hip
/// span. Setting both to 1.0 is neutral; setting `shoulderScale > hipScale`
/// simulates leaning toward the camera; `shoulderScale < hipScale`
/// simulates leaning back.
PoseResult buildPose({
  double shoulderScale = 1.0,
  double hipScale = 1.0,
  double visibility = 0.95,
}) {
  PoseLandmark lm(int t, double x, double y) =>
      PoseLandmark(type: t, x: x, y: y, confidence: visibility);
  const cx = 0.5;
  const cy = 0.5;
  final shoulderHalf = 0.10 * shoulderScale;
  final hipHalf = 0.07 * hipScale;
  // Vertical torso length grows with shoulder distance from camera too —
  // the foreshortening of a leaning torso also shrinks the apparent
  // vertical separation a bit, but for test purposes scaling with
  // `shoulderScale` produces a usable f₃ signal.
  final torsoHalf = 0.10 * shoulderScale;
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, cx - shoulderHalf, cy - torsoHalf),
      lm(LM.rightShoulder, cx + shoulderHalf, cy - torsoHalf),
      lm(LM.leftHip, cx - hipHalf, cy + torsoHalf),
      lm(LM.rightHip, cx + hipHalf, cy + torsoHalf),
    ],
  );
}

void main() {
  group('SagittalSwayDetector', () {
    test('reports neutral and non-ready before baseline window fills', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      // Feed fewer than the baseline-min frames.
      for (var i = 0; i < kSagittalBaselineMinFrames - 1; i++) {
        final r = detector.update(
          pose: buildPose(),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
        expect(r.baselineReady, isFalse);
        expect(r.direction, SagittalSwayDirection.neutral);
        expect(r.compositeZ, isNull);
      }
    });

    test('clean stationary pose stays neutral after baseline ready', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      // Fill baseline.
      for (var i = 0; i < kSagittalBaselineMinFrames; i++) {
        detector.update(
          pose: buildPose(),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      expect(detector.baselineReady, isTrue);
      // Feed more identical frames as if the user is not moving.
      var observed = SagittalSwayDirection.neutral;
      for (var i = 0; i < 30; i++) {
        final r = detector.update(
          pose: buildPose(),
          now: t0.add(
            Duration(milliseconds: 33 * (kSagittalBaselineMinFrames + i)),
          ),
          allowBaseline: false,
        );
        if (r.direction != SagittalSwayDirection.neutral) {
          observed = r.direction;
        }
      }
      expect(observed, SagittalSwayDirection.neutral);
    });

    test('forward sway (shoulders proportionally larger) trips forward', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      // Tight baseline with tiny uniform jitter so σ > 0 floor.
      for (var i = 0; i < kSagittalBaselineMinFrames; i++) {
        final j = (i % 2 == 0) ? 1.0 : 1.001;
        detector.update(
          pose: buildPose(shoulderScale: j, hipScale: j),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      // Forward sway: shoulders grow faster than hips (upper body pitches
      // toward the camera). 1€ filter damps short transients, so the
      // ramp is sustained over ~60 frames (~2s at 30fps).
      var sawForward = false;
      for (var i = 0; i < 60; i++) {
        final r = detector.update(
          pose: buildPose(shoulderScale: 1.0 + 0.01 * (i + 1), hipScale: 1.0),
          now: t0.add(
            Duration(milliseconds: 33 * (kSagittalBaselineMinFrames + i)),
          ),
          allowBaseline: false,
        );
        if (r.direction == SagittalSwayDirection.forward) {
          sawForward = true;
          break;
        }
      }
      expect(
        sawForward,
        isTrue,
        reason:
            'Sustained shoulder-grows-vs-hip should trip forward classification',
      );
    });

    test('backward sway (shoulders proportionally smaller) trips backward', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      for (var i = 0; i < kSagittalBaselineMinFrames; i++) {
        final j = (i % 2 == 0) ? 1.0 : 1.001;
        detector.update(
          pose: buildPose(shoulderScale: j, hipScale: j),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      // Backward sway: shoulders shrink while hips stay put (upper body
      // pitches away from the camera).
      var sawBackward = false;
      for (var i = 0; i < 60; i++) {
        final r = detector.update(
          pose: buildPose(shoulderScale: 1.0 - 0.01 * (i + 1), hipScale: 1.0),
          now: t0.add(
            Duration(milliseconds: 33 * (kSagittalBaselineMinFrames + i)),
          ),
          allowBaseline: false,
        );
        if (r.direction == SagittalSwayDirection.backward) {
          sawBackward = true;
          break;
        }
      }
      expect(sawBackward, isTrue);
    });

    test('low-visibility frames are dropped (no baseline progression)', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      // All frames below the visibility gate.
      for (var i = 0; i < kSagittalBaselineMinFrames * 2; i++) {
        detector.update(
          pose: buildPose(visibility: 0.1),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      expect(
        detector.baselineReady,
        isFalse,
        reason: 'Visibility-gated frames must not advance the baseline',
      );
    });

    test('dt anomaly suppresses velocity for that step', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      for (var i = 0; i < kSagittalBaselineMinFrames; i++) {
        final j = (i % 2 == 0) ? 1.0 : 1.001;
        detector.update(
          pose: buildPose(shoulderScale: j, hipScale: j),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      // Take several normal steps to populate the dt window — the
      // anomaly check is no-op while the window is empty, so we need
      // ≥ 1 prior dt sample for a meaningful test.
      for (var i = 1; i <= 5; i++) {
        detector.update(
          pose: buildPose(),
          now: t0.add(
            Duration(milliseconds: 33 * (kSagittalBaselineMinFrames + i)),
          ),
          allowBaseline: false,
        );
      }
      // Now jump dt ~30× forward — velocity computation must be skipped
      // so the spike doesn't poison the output.
      final anomalous = detector.update(
        pose: buildPose(shoulderScale: 1.5),
        now: t0.add(
          Duration(milliseconds: 33 * (kSagittalBaselineMinFrames + 5) + 1000),
        ),
        allowBaseline: false,
      );
      expect(
        anomalous.velocityPerSec,
        isNull,
        reason: 'Anomalous dt must suppress this frame\'s velocity',
      );
    });

    test('reset clears baseline and direction', () {
      final detector = SagittalSwayDetector();
      final t0 = DateTime(2026);
      for (var i = 0; i < kSagittalBaselineMinFrames; i++) {
        detector.update(
          pose: buildPose(),
          now: t0.add(Duration(milliseconds: 33 * i)),
          allowBaseline: true,
        );
      }
      expect(detector.baselineReady, isTrue);
      detector.reset();
      expect(detector.baselineReady, isFalse);
      // Next update without a fresh baseline must report not-ready.
      final r = detector.update(
        pose: buildPose(),
        now: t0.add(const Duration(seconds: 5)),
        allowBaseline: false,
      );
      expect(r.baselineReady, isFalse);
      expect(r.direction, SagittalSwayDirection.neutral);
    });
  });
}
