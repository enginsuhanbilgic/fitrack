import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/setup_framing_check.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

PoseLandmark _lm(int type, double x, double y, [double conf = 0.9]) =>
    PoseLandmark(type: type, x: x, y: y, confidence: conf);

/// Builds an "ideal" curl-setup pose:
///   nose at top with margin, shoulder & hip straddling y=0.5 (mid-chest at
///   lens height), wrist near (but above) the bottom margin, torso vertical.
///
/// Individual tests then mutate ONE landmark to exercise the corresponding
/// signal — keeping the rest of the body in a valid configuration.
PoseResult _idealPose({
  double noseY = 0.20,
  double shoulderY = 0.40,
  double hipY = 0.60,
  double wristY = 0.70,
  double shoulderX = 0.50,
  double hipX = 0.50,
  bool leftSide = true,
}) {
  final s = leftSide ? LM.leftShoulder : LM.rightShoulder;
  final h = leftSide ? LM.leftHip : LM.rightHip;
  final w = leftSide ? LM.leftWrist : LM.rightWrist;
  return PoseResult(
    landmarks: [
      _lm(LM.nose, 0.50, noseY),
      _lm(s, shoulderX, shoulderY),
      _lm(h, hipX, hipY),
      _lm(w, shoulderX, wristY),
    ],
    inferenceTime: Duration.zero,
  );
}

void main() {
  group('evaluateSetupFraming — happy path', () {
    test(
      'passes for ideal mid-chest framing with full arm and head visible',
      () {
        final r = evaluateSetupFraming(_idealPose());
        expect(r.ok, isTrue);
        expect(r.hint, isNull);
        expect(r.midChestY, closeTo(0.5, 1e-9));
        expect(r.tiltDeg, closeTo(0.0, 1e-9));
      },
    );
  });

  group('evaluateSetupFraming — head/arm coverage', () {
    test('fails when head is clipping the top', () {
      final r = evaluateSetupFraming(_idealPose(noseY: 0.02));
      expect(r.ok, isFalse);
      expect(r.hint, contains('Head is clipping'));
    });

    test('fails when wrist clips the bottom edge', () {
      final r = evaluateSetupFraming(_idealPose(wristY: 0.97));
      expect(r.ok, isFalse);
      expect(r.hint, contains('Wrist is clipping'));
    });

    test('fails with "head not visible" hint when nose landmark is absent', () {
      final pose = PoseResult(
        landmarks: [
          _lm(LM.leftShoulder, 0.50, 0.40),
          _lm(LM.leftHip, 0.50, 0.60),
          _lm(LM.leftWrist, 0.50, 0.70),
          // no nose
        ],
        inferenceTime: Duration.zero,
      );
      final r = evaluateSetupFraming(pose);
      expect(r.ok, isFalse);
      expect(r.hint, contains('Head not visible'));
    });

    test(
      'fails with "arm not fully visible" when wrist landmark is absent',
      () {
        final pose = PoseResult(
          landmarks: [
            _lm(LM.nose, 0.50, 0.20),
            _lm(LM.leftShoulder, 0.50, 0.40),
            _lm(LM.leftHip, 0.50, 0.60),
            // no wrist on either side
          ],
          inferenceTime: Duration.zero,
        );
        final r = evaluateSetupFraming(pose);
        expect(r.ok, isFalse);
        expect(r.hint, contains('Arm not fully visible'));
      },
    );
  });

  group('evaluateSetupFraming — camera height (mid-chest)', () {
    test('fails when body sits low in frame (camera too high)', () {
      // Mid-chest at y=0.75 → delta +0.25, above 0.12 tolerance.
      final r = evaluateSetupFraming(
        _idealPose(noseY: 0.55, shoulderY: 0.70, hipY: 0.80, wristY: 0.90),
      );
      expect(r.ok, isFalse);
      expect(r.hint, contains('Lower the camera'));
    });

    test('fails when body sits high in frame (camera too low)', () {
      // Mid-chest at y=0.20 → delta -0.30, below -0.12.
      final r = evaluateSetupFraming(
        _idealPose(noseY: 0.05, shoulderY: 0.15, hipY: 0.25, wristY: 0.40),
      );
      // Head margin trips first (noseY 0.05 still passes 0.04 head margin),
      // so this exercises mid-chest. Verify.
      expect(r.ok, isFalse);
      expect(r.hint, contains('Raise the camera'));
    });

    test('accepts mid-chest within ±tolerance of 0.5', () {
      // midChestY = 0.55 → delta +0.05, well inside ±0.12.
      final r = evaluateSetupFraming(
        _idealPose(shoulderY: 0.45, hipY: 0.65, wristY: 0.78),
      );
      expect(r.ok, isTrue);
      expect(
        (r.midChestY! - kSetupMidChestTarget).abs(),
        lessThan(kSetupMidChestTolerance),
      );
    });
  });

  group('evaluateSetupFraming — torso tilt', () {
    test('fails when shoulder-hip line tilts past threshold', () {
      // dx 0.20, dy 0.20 → 45° tilt, above 25°.
      final r = evaluateSetupFraming(_idealPose(shoulderX: 0.35, hipX: 0.55));
      expect(r.ok, isFalse);
      expect(r.hint, contains('level'));
      expect(r.tiltDeg! > kSetupTorsoTiltMaxDeg, isTrue);
    });

    test('accepts mild tilt under threshold', () {
      // ~14° tilt, within tolerance.
      final r = evaluateSetupFraming(_idealPose(shoulderX: 0.47, hipX: 0.52));
      expect(r.ok, isTrue);
    });
  });

  group('evaluateSetupFraming — degenerate input', () {
    test('returns "step into frame" when no shoulder-hip pair resolves', () {
      final r = evaluateSetupFraming(
        PoseResult(landmarks: const [], inferenceTime: Duration.zero),
      );
      expect(r.ok, isFalse);
      expect(r.hint, contains('Step into frame'));
    });

    test('selects higher-confidence side when both are present', () {
      // Left side has low confidence and bad framing; right side has high
      // confidence and ideal framing — must pass on the right.
      final pose = PoseResult(
        landmarks: [
          _lm(LM.nose, 0.50, 0.20),
          _lm(LM.leftShoulder, 0.30, 0.10, 0.7),
          _lm(LM.leftHip, 0.30, 0.15, 0.7),
          _lm(LM.leftWrist, 0.30, 0.99, 0.7), // would clip
          _lm(LM.rightShoulder, 0.50, 0.40, 0.95),
          _lm(LM.rightHip, 0.50, 0.60, 0.95),
          _lm(LM.rightWrist, 0.50, 0.70, 0.95),
        ],
        inferenceTime: Duration.zero,
      );
      final r = evaluateSetupFraming(pose);
      expect(r.ok, isTrue);
    });
  });
}
