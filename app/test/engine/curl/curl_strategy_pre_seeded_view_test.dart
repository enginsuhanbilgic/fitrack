/// Tests for pre-seeded view behavior in [CurlStrategy].
///
/// History: pre-seeded sessions (those constructed with a non-unknown
/// [initialView]) used to short-circuit runtime view re-detection
/// entirely. That silently produced wrong-side bucket attribution if the
/// user rotated mid-session. The Runtime View Re-detection change removed
/// that early-return — pre-seeded sessions now re-detect like everyone
/// else, BUT the FSM-idle gate + hysteresis still preserve invariant 10.
/// These tests cover both halves of the new contract.
library;

import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_strategy.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

// Re-use the pose builders from the sibling strategy test file.
PoseResult _buildFrontPose() {
  PoseLandmark lm(int t, double x, double y) =>
      PoseLandmark(type: t, x: x, y: y, confidence: 0.9);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.40, 0.30),
      lm(LM.rightShoulder, 0.60, 0.30),
      lm(LM.leftElbow, 0.40, 0.50),
      lm(LM.rightElbow, 0.60, 0.50),
      lm(LM.leftWrist, 0.40, 0.65),
      lm(LM.rightWrist, 0.60, 0.65),
      lm(LM.leftHip, 0.46, 0.70),
      lm(LM.rightHip, 0.54, 0.70),
      lm(LM.nose, 0.50, 0.20),
    ],
  );
}

PoseResult _buildSideLeftPose() {
  PoseLandmark lm(int t, double x, double y, double c) =>
      PoseLandmark(type: t, x: x, y: y, confidence: c);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.49, 0.30, 0.95),
      lm(LM.rightShoulder, 0.51, 0.30, 0.40),
      lm(LM.leftElbow, 0.49, 0.50, 0.9),
      lm(LM.rightElbow, 0.51, 0.50, 0.4),
      lm(LM.leftWrist, 0.49, 0.65, 0.9),
      lm(LM.rightWrist, 0.51, 0.65, 0.4),
      lm(LM.leftHip, 0.49, 0.70, 0.9),
      lm(LM.rightHip, 0.51, 0.70, 0.4),
      lm(LM.nose, 0.45, 0.20, 0.9),
    ],
  );
}

void _driveFrames(
  CurlStrategy strategy,
  PoseResult pose,
  int count, {
  RepState state = RepState.idle,
  double smoothedAngle = 160.0,
}) {
  for (var i = 0; i < count; i++) {
    strategy.tick(
      StrategyFrameInput(
        pose: pose,
        smoothedAngle: smoothedAngle,
        now: DateTime.now(),
        state: state,
        repIndexInSet: 0,
      ),
    );
  }
}

void main() {
  group('CurlStrategy — pre-seeded front view', () {
    test('exercise getter returns bicepsCurlFront', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlFront,
        initialView: CurlCameraView.front,
      );
      expect(s.exercise, ExerciseType.bicepsCurlFront);
    });

    test('lockedView is front immediately after construction', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlFront,
        initialView: CurlCameraView.front,
      );
      expect(s.lockedView, CurlCameraView.front);
    });

    test(
      'lockedView stays front mid-rep even past hysteresis (invariant 10)',
      () {
        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlFront,
          initialView: CurlCameraView.front,
        );
        // 20 conflicting-view frames during CONCENTRIC must NOT flip — the
        // FSM-idle gate is what preserves the no-mid-rep-flip invariant.
        _driveFrames(
          s,
          _buildSideLeftPose(),
          20,
          state: RepState.concentric,
          smoothedAngle: 80,
        );
        expect(s.lockedView, CurlCameraView.front);
      },
    );

    test('updateSetupView returns front without overriding it', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlFront,
        initialView: CurlCameraView.front,
      );
      final pose = _buildSideLeftPose();
      for (var i = 0; i < 20; i++) {
        final result = s.updateSetupView(pose);
        expect(result, CurlCameraView.front);
      }
      expect(s.lockedView, CurlCameraView.front);
    });
  });

  group('CurlStrategy — pre-seeded side-left view', () {
    test('exercise getter returns bicepsCurlSide', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideLeft,
      );
      expect(s.exercise, ExerciseType.bicepsCurlSide);
    });

    test('lockedView is sideLeft immediately after construction', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideLeft,
      );
      expect(s.lockedView, CurlCameraView.sideLeft);
    });

    test(
      'lockedView stays sideLeft mid-rep even past hysteresis (invariant 10)',
      () {
        final s = CurlStrategy(
          exerciseType: ExerciseType.bicepsCurlSide,
          initialView: CurlCameraView.sideLeft,
        );
        _driveFrames(
          s,
          _buildFrontPose(),
          20,
          state: RepState.concentric,
          smoothedAngle: 80,
        );
        expect(s.lockedView, CurlCameraView.sideLeft);
      },
    );
  });

  group('CurlStrategy — no pre-seed (legacy behavior)', () {
    test('lockedView starts unknown when no initialView given', () {
      final s = CurlStrategy();
      expect(s.lockedView, CurlCameraView.unknown);
    });

    test('exercise getter defaults to bicepsCurlFront', () {
      final s = CurlStrategy();
      expect(s.exercise, ExerciseType.bicepsCurlFront);
    });
  });
}
