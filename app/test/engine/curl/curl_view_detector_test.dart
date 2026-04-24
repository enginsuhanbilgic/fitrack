import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_view_detector.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

/// Build a synthetic pose tuned for view-detector tests.
///
/// `shoulderSep` controls horizontal separation of left/right shoulders (the
/// detector's primary evidence). `leftConf`/`rightConf` drive confidence
/// asymmetry (second signal). `noseX` drives nose offset from shoulder
/// midpoint (third signal). All coordinates are normalized to [0, 1].
PoseResult _viewPose({
  required double shoulderSep,
  double leftConf = 0.9,
  double rightConf = 0.9,
  double? noseX,
  double midX = 0.5,
}) {
  final halfSep = shoulderSep / 2.0;
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      PoseLandmark(
        type: LM.leftShoulder,
        x: midX - halfSep,
        y: 0.30,
        confidence: leftConf,
      ),
      PoseLandmark(
        type: LM.rightShoulder,
        x: midX + halfSep,
        y: 0.30,
        confidence: rightConf,
      ),
      PoseLandmark(type: LM.nose, x: noseX ?? midX, y: 0.20, confidence: 0.9),
    ],
  );
}

void main() {
  late CurlViewDetector det;

  setUp(() => det = CurlViewDetector());

  group('initial classifyFrame (no lock yet)', () {
    test('separation 0.16 classifies as front (strict thresholds)', () {
      final pose = _viewPose(shoulderSep: 0.16);
      expect(det.classifyFrame(pose), CurlCameraView.front);
    });

    test('separation 0.08 with corroborating signals classifies as side', () {
      final pose = _viewPose(
        shoulderSep: 0.08,
        leftConf: 0.9,
        rightConf: 0.5,
        noseX: 0.35,
      );
      expect(det.classifyFrame(pose), isNot(CurlCameraView.front));
      expect(det.classifyFrame(pose), isNot(CurlCameraView.unknown));
    });
  });

  group('hysteresis post-lock — front-locked', () {
    test('separation 0.09 does NOT flip to side (inside hysteresis band)', () {
      // Side threshold strict = 0.10; with front lock, requires sep ≤ 0.07.
      // 0.09 is inside the band, so single-signal side-evidence is suppressed.
      final pose = _viewPose(shoulderSep: 0.09);
      final result = det.classifyFrame(
        pose,
        currentLocked: CurlCameraView.front,
      );
      expect(result, isNot(CurlCameraView.sideLeft));
      expect(result, isNot(CurlCameraView.sideRight));
    });

    test('separation 0.06 with corroborating signals DOES flip to side', () {
      // Sep 0.06 ≤ 0.07 (strict − delta) → satisfies hysteresis band.
      // Add confidence asymmetry + nose offset for 3-of-3 side evidence.
      final pose = _viewPose(
        shoulderSep: 0.06,
        leftConf: 0.9,
        rightConf: 0.5,
        noseX: 0.35,
      );
      final result = det.classifyFrame(
        pose,
        currentLocked: CurlCameraView.front,
      );
      expect(result, anyOf(CurlCameraView.sideLeft, CurlCameraView.sideRight));
    });
  });

  group('hysteresis post-lock — side-locked', () {
    test('separation 0.16 does NOT flip to front (inside hysteresis band)', () {
      // Front threshold strict = 0.15; with side lock, requires sep ≥ 0.18.
      // 0.16 is inside the band, so front-evidence is suppressed.
      final pose = _viewPose(
        shoulderSep: 0.16,
        leftConf: 0.9,
        rightConf: 0.5, // keep confidence asymmetry so side signal stays on
        noseX: 0.35,
      );
      final result = det.classifyFrame(
        pose,
        currentLocked: CurlCameraView.sideLeft,
      );
      expect(result, isNot(CurlCameraView.front));
    });

    test('separation 0.19 with front-symmetric signals DOES flip to front', () {
      // Sep 0.19 ≥ 0.18 (strict + delta) → crosses hysteresis band.
      final pose = _viewPose(shoulderSep: 0.19);
      final result = det.classifyFrame(
        pose,
        currentLocked: CurlCameraView.sideLeft,
      );
      expect(result, CurlCameraView.front);
    });
  });

  group('reset', () {
    test('reset restores unknown and allows a fresh lock path', () {
      // Drive enough front-looking frames to lock initially.
      final frontPose = _viewPose(shoulderSep: 0.20);
      for (var i = 0; i < 30; i++) {
        det.update(frontPose);
      }
      expect(det.isLocked, isTrue);
      expect(det.detectedView, CurlCameraView.front);

      det.reset();
      expect(det.isLocked, isFalse);
      expect(det.detectedView, CurlCameraView.unknown);
    });
  });
}
