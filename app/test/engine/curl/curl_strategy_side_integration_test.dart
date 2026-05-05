/// Integration tests for [CurlStrategy] in side-view mode.
///
/// Drives full rep lifecycle (IDLE→CONCENTRIC→PEAK→ECCENTRIC→IDLE), verifies
/// the rep-commit callback fires exactly once, and asserts that [attributedSide]
/// follows bilateral-angle availability rather than the analyzer's anatomical
/// arm resolution.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_strategy.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

// ── Shared helpers ─────────────────────────────────────────────────────────

RomThresholds _legacyProvider(ProfileSide _, CurlCameraView _, int _) =>
    const RomThresholds(
      startAngle: kCurlStartAngle,
      peakAngle: kCurlPeakAngle,
      peakExitAngle: kCurlPeakExitAngle,
      endAngle: kCurlEndAngle,
      source: ThresholdSource.global,
    );

/// Left arm at high confidence, right arm at low confidence.
/// Nose is to the left of shoulder → _facingRight = false.
/// Wrists included so _computeBilateralAngle can resolve the left side.
PoseResult _buildSideLeftPose({double confidence = 0.9}) {
  PoseLandmark hi(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);
  PoseLandmark lo(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: 0.05);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      hi(LM.nose, 0.30, 0.15),
      hi(LM.leftShoulder, 0.50, 0.30),
      hi(LM.leftElbow, 0.50, 0.50),
      hi(LM.leftWrist, 0.50, 0.70),
      hi(LM.leftHip, 0.50, 0.70),
      lo(LM.rightShoulder, 0.60, 0.30),
      lo(LM.rightElbow, 0.60, 0.50),
      lo(LM.rightWrist, 0.60, 0.70),
      lo(LM.rightHip, 0.60, 0.70),
    ],
  );
}

/// Right arm at high confidence, left arm at low confidence.
PoseResult _buildRightOnlyPose({double confidence = 0.9}) {
  PoseLandmark hi(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);
  PoseLandmark lo(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: 0.05);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      hi(LM.nose, 0.70, 0.15),
      hi(LM.rightShoulder, 0.50, 0.30),
      hi(LM.rightElbow, 0.50, 0.50),
      hi(LM.rightWrist, 0.50, 0.70),
      hi(LM.rightHip, 0.50, 0.70),
      lo(LM.leftShoulder, 0.40, 0.30),
      lo(LM.leftElbow, 0.40, 0.50),
      lo(LM.leftWrist, 0.40, 0.70),
      lo(LM.leftHip, 0.40, 0.70),
    ],
  );
}

/// Both wrists at low confidence → neither bilateral angle computable.
PoseResult _buildNoBilateralPose({double confidence = 0.9}) {
  PoseLandmark hi(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);
  PoseLandmark lo(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: 0.05);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      hi(LM.nose, 0.30, 0.15),
      hi(LM.leftShoulder, 0.50, 0.30),
      hi(LM.leftElbow, 0.50, 0.50),
      lo(LM.leftWrist, 0.50, 0.70),
      hi(LM.leftHip, 0.50, 0.70),
      hi(LM.rightShoulder, 0.60, 0.30),
      hi(LM.rightElbow, 0.60, 0.50),
      lo(LM.rightWrist, 0.60, 0.70),
      hi(LM.rightHip, 0.60, 0.70),
    ],
  );
}

StrategyFrameOutput _tick(
  CurlStrategy s,
  RepState state,
  double angle,
  PoseResult pose,
) => s.tick(
  StrategyFrameInput(
    state: state,
    smoothedAngle: angle,
    pose: pose,
    repIndexInSet: 0,
    now: DateTime.now(),
  ),
);

void _driveFullRep(CurlStrategy s, PoseResult pose) {
  _tick(s, RepState.idle, 150, pose);
  _tick(s, RepState.concentric, 60, pose);
  _tick(s, RepState.peak, 90, pose);
  _tick(s, RepState.eccentric, 145, pose);
}

// ── Tests ──────────────────────────────────────────────────────────────────

void main() {
  group('CurlStrategy — side-view full rep lifecycle', () {
    test(
      'pre-seeded sideLeft drives IDLE→CONCENTRIC→PEAK→ECCENTRIC→IDLE and commits once',
      () {
        var commitCount = 0;
        CurlCameraView? committedView;

        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlSide,
          initialView: CurlCameraView.sideLeft,
          thresholdsProvider: _legacyProvider,
          onRepCommit:
              ({
                required side,
                required view,
                required minAngle,
                required maxAngle,
                required concentricDuration,
                double? minAtPeak,
              }) {
                commitCount++;
                committedView = view;
              },
        );

        final pose = _buildSideLeftPose();

        // IDLE — angle above startAngle (160) → stays idle.
        var out = _tick(s, RepState.idle, 170, pose);
        expect(out.nextState, RepState.idle);

        // IDLE — angle drops below startAngle → transitions to concentric.
        out = _tick(s, RepState.idle, 150, pose);
        expect(out.nextState, RepState.concentric);

        // CONCENTRIC — angle reaches peak (≤ 70) → transitions to peak.
        out = _tick(s, RepState.concentric, 60, pose);
        expect(out.nextState, RepState.peak);

        // PEAK — angle exceeds peakExitAngle (85) → transitions to eccentric.
        out = _tick(s, RepState.peak, 90, pose);
        expect(out.nextState, RepState.eccentric);

        // ECCENTRIC — angle reaches endAngle (≥ 140) → rep committed, back to idle.
        out = _tick(s, RepState.eccentric, 145, pose);
        expect(out.nextState, RepState.idle);
        expect(out.repCommitted, isTrue);

        expect(commitCount, 1);
        expect(committedView, CurlCameraView.sideLeft);
        expect(s.lockedView, CurlCameraView.sideLeft);
      },
    );
  });

  group('CurlStrategy — attributedSide follows bilateral-angle availability', () {
    test(
      'only left bilateral angle computable → commits with ProfileSide.left',
      () {
        ProfileSide? committed;
        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlSide,
          initialView: CurlCameraView.sideLeft,
          thresholdsProvider: _legacyProvider,
          onRepCommit:
              ({
                required side,
                required view,
                required minAngle,
                required maxAngle,
                required concentricDuration,
                double? minAtPeak,
              }) {
                committed = side;
              },
        );
        _driveFullRep(s, _buildSideLeftPose());
        expect(committed, ProfileSide.left);
      },
    );

    test(
      'only right bilateral angle computable → commits with ProfileSide.right',
      () {
        ProfileSide? committed;
        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlSide,
          initialView: CurlCameraView.sideLeft,
          thresholdsProvider: _legacyProvider,
          onRepCommit:
              ({
                required side,
                required view,
                required minAngle,
                required maxAngle,
                required concentricDuration,
                double? minAtPeak,
              }) {
                committed = side;
              },
        );
        _driveFullRep(s, _buildRightOnlyPose());
        expect(committed, ProfileSide.right);
      },
    );

    test(
      'no bilateral angle computable → falls back to _profileSideForRep()',
      () {
        // side: ExerciseSide.right → _profileSideForRep() returns ProfileSide.right
        ProfileSide? committed;
        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlSide,
          initialView: CurlCameraView.sideLeft,
          side: ExerciseSide.right,
          thresholdsProvider: _legacyProvider,
          onRepCommit:
              ({
                required side,
                required view,
                required minAngle,
                required maxAngle,
                required concentricDuration,
                double? minAtPeak,
              }) {
                committed = side;
              },
        );
        _driveFullRep(s, _buildNoBilateralPose());
        expect(committed, ProfileSide.right);
      },
    );
  });

  group('CurlStrategy — pre-seeded view never auto-flips', () {
    test('sideLeft stays locked after 25 frames of right-biased poses', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideLeft,
        thresholdsProvider: _legacyProvider,
      );

      // Right-biased pose — auto-detect would classify as sideRight, but
      // pre-seeded sessions short-circuit _updateActiveViewDetection entirely.
      final rightBiased = _buildRightOnlyPose();
      for (var i = 0; i < 25; i++) {
        _tick(s, RepState.idle, 170, rightBiased);
      }

      expect(s.lockedView, CurlCameraView.sideLeft);
    });
  });
}
