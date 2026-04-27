/// Tests for runtime view re-detection in [CurlStrategy].
///
/// Contract (after the side-view lock-in fix):
///
/// 1. **Pre-seeded sessions** — those whose constructor received a
///    non-unknown `initialView` (i.e. the user picked the view at
///    home-screen time) — NEVER auto-flip. The view is locked for the
///    entire session. The user can finish the workout and start a new
///    one with a different view.
///
/// 2. **Legacy auto-detect sessions** — those whose constructor received
///    no `initialView` — keep the old re-detection behavior: hysteresis +
///    FSM-idle gate (invariant 10).
///
/// Also covers the [CurlViewFlipCallback] contract for the legacy path
/// and the front-analyzer dormancy gate.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_strategy.dart';
import 'package:fitrack/engine/exercise_strategy.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

// Pose with shoulders ~0.20 apart, symmetric confidences, nose centered →
// classifies as front view.
PoseResult _frontPose() {
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

// Pose with shoulders ~0.02 apart, left-side dominant confidences, nose
// offset to the left → classifies as sideLeft.
PoseResult _sideLeftPose() {
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

// Pose with shoulders ~0.02 apart, right-side dominant confidences, nose
// offset to the right → classifies as sideRight.
PoseResult _sideRightPose() {
  PoseLandmark lm(int t, double x, double y, double c) =>
      PoseLandmark(type: t, x: x, y: y, confidence: c);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.49, 0.30, 0.40),
      lm(LM.rightShoulder, 0.51, 0.30, 0.95),
      lm(LM.leftElbow, 0.49, 0.50, 0.4),
      lm(LM.rightElbow, 0.51, 0.50, 0.9),
      lm(LM.leftWrist, 0.49, 0.65, 0.4),
      lm(LM.rightWrist, 0.51, 0.65, 0.9),
      lm(LM.leftHip, 0.49, 0.70, 0.4),
      lm(LM.rightHip, 0.51, 0.70, 0.9),
      lm(LM.nose, 0.55, 0.20, 0.9),
    ],
  );
}

// Pose with all landmarks low-confidence — classifies as unknown.
PoseResult _unknownPose() {
  PoseLandmark lm(int t, double x, double y, double c) =>
      PoseLandmark(type: t, x: x, y: y, confidence: c);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.leftShoulder, 0.45, 0.30, 0.5),
      lm(LM.rightShoulder, 0.53, 0.30, 0.5),
      lm(LM.nose, 0.49, 0.20, 0.5),
    ],
  );
}

void _drive(
  CurlStrategy s,
  PoseResult pose,
  int n, {
  RepState state = RepState.idle,
  double smoothedAngle = 160.0,
}) {
  for (var i = 0; i < n; i++) {
    s.tick(
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
  group('CurlStrategy — pre-seeded sessions never auto-flip', () {
    test('pre-seeded sideRight session does NOT flip to sideLeft even with '
        'opposing-view frames + hysteresis satisfied at idle', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideRight,
        onViewFlipped: (from, to) => flips.add((from, to)),
      );
      _drive(s, _sideLeftPose(), kViewRedetectHysteresisFrames * 3);
      expect(s.lockedView, CurlCameraView.sideRight);
      expect(flips, isEmpty);
    });

    test('pre-seeded sideLeft session does NOT flip to sideRight even with '
        'opposing-view frames at idle', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideLeft,
        onViewFlipped: (from, to) => flips.add((from, to)),
      );
      _drive(s, _sideRightPose(), kViewRedetectHysteresisFrames * 3);
      expect(s.lockedView, CurlCameraView.sideLeft);
      expect(flips, isEmpty);
    });

    test('pre-seeded sideLeft session does NOT flip to front even with '
        'opposing-view frames at idle', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideLeft,
        onViewFlipped: (from, to) => flips.add((from, to)),
      );
      _drive(s, _frontPose(), kViewRedetectHysteresisFrames * 3);
      expect(s.lockedView, CurlCameraView.sideLeft);
      expect(flips, isEmpty);
    });

    test('pre-seeded front-curl session does NOT flip to side mid-workout', () {
      // Front-curl sessions are also pre-seeded (initialView = front).
      // Same lock-in contract applies — a brief framing change must not
      // tear down the front analyzer.
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlFront,
        initialView: CurlCameraView.front,
        onViewFlipped: (from, to) => flips.add((from, to)),
      );
      _drive(s, _sideLeftPose(), kViewRedetectHysteresisFrames * 3);
      expect(s.lockedView, CurlCameraView.front);
      expect(flips, isEmpty);
    });

    test('mid-rep opposing-view frames do not flip and do not buffer for '
        'the next idle on pre-seeded sessions', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideRight,
        onViewFlipped: (from, to) => flips.add((from, to)),
      );
      // Build streak during CONCENTRIC — must NOT flip and must NOT
      // buffer (would otherwise apply at next IDLE).
      _drive(
        s,
        _sideLeftPose(),
        kViewRedetectHysteresisFrames * 2,
        state: RepState.concentric,
        smoothedAngle: 80,
      );
      // One IDLE frame: nothing buffered → no flip even though
      // hysteresis was nominally satisfied.
      _drive(s, _sideLeftPose(), 1);
      expect(s.lockedView, CurlCameraView.sideRight);
      expect(flips, isEmpty);
    });

    test('onNextSet preserves the pre-seeded view', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideRight,
      );
      _drive(s, _sideLeftPose(), kViewRedetectHysteresisFrames + 2);
      expect(s.lockedView, CurlCameraView.sideRight);
      s.onNextSet();
      expect(s.lockedView, CurlCameraView.sideRight);
    });

    test('onReset preserves the pre-seeded view', () {
      final s = CurlStrategy(
        exerciseType: ExerciseType.bicepsCurlSide,
        initialView: CurlCameraView.sideRight,
      );
      _drive(s, _sideLeftPose(), kViewRedetectHysteresisFrames + 2);
      expect(s.lockedView, CurlCameraView.sideRight);
      s.onReset();
      expect(s.lockedView, CurlCameraView.sideRight);
    });
  });

  group('CurlStrategy — legacy auto-detect path (no pre-seed) still works', () {
    test(
      'unknown→sideLeft via updateSetupView does NOT fire onViewFlipped',
      () {
        final flips = <(CurlCameraView, CurlCameraView)>[];
        final s = CurlStrategy(
          // No initialView — locks via updateSetupView.
          onViewFlipped: (from, to) => flips.add((from, to)),
        );
        final pose = _sideLeftPose();
        for (var i = 0; i < 60; i++) {
          s.updateSetupView(pose);
        }
        expect(s.lockedView, CurlCameraView.sideLeft);
        // First lock is "first detection", not a flip — must NOT fire.
        expect(flips, isEmpty);
      },
    );

    test(
      'after legacy lock, opposing-view frames at idle DO trigger a flip',
      () {
        final flips = <(CurlCameraView, CurlCameraView)>[];
        final s = CurlStrategy(onViewFlipped: (f, t) => flips.add((f, t)));
        // Lock to sideLeft via setup-view loop.
        for (var i = 0; i < 60; i++) {
          s.updateSetupView(_sideLeftPose());
        }
        expect(s.lockedView, CurlCameraView.sideLeft);
        // Now drive opposing-view ticks — the legacy path is allowed to
        // re-detect because the session was not pre-seeded.
        _drive(s, _sideRightPose(), kViewRedetectHysteresisFrames + 5);
        expect(s.lockedView, CurlCameraView.sideRight);
        expect(flips, [(CurlCameraView.sideLeft, CurlCameraView.sideRight)]);
      },
    );

    test('legacy path still respects invariant 10 — no mid-rep flip', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(onViewFlipped: (f, t) => flips.add((f, t)));
      for (var i = 0; i < 60; i++) {
        s.updateSetupView(_sideLeftPose());
      }
      _drive(
        s,
        _sideRightPose(),
        kViewRedetectHysteresisFrames * 3,
        state: RepState.concentric,
        smoothedAngle: 80,
      );
      expect(s.lockedView, CurlCameraView.sideLeft);
      expect(flips, isEmpty);
    });

    test('legacy path: unknown candidate never triggers a flip', () {
      final flips = <(CurlCameraView, CurlCameraView)>[];
      final s = CurlStrategy(onViewFlipped: (f, t) => flips.add((f, t)));
      for (var i = 0; i < 60; i++) {
        s.updateSetupView(_sideLeftPose());
      }
      _drive(s, _unknownPose(), kViewRedetectHysteresisFrames * 2);
      expect(s.lockedView, CurlCameraView.sideLeft);
      expect(flips, isEmpty);
    });
  });

  group('CurlStrategy — front-analyzer dormancy gate', () {
    test('flip to front (legacy path) does NOT swap analyzer when '
        'kCurlFrontViewEnabled is false', () {
      // Guards the dormancy gate while front view is hidden.
      // If kCurlFrontViewEnabled is flipped, this test must be revisited.
      expect(
        kCurlFrontViewEnabled,
        isFalse,
        reason:
            'This test guards the dormancy gate while front view is hidden.',
      );
      final s = CurlStrategy();
      // Lock to sideLeft via setup loop, then auto-flip to front.
      for (var i = 0; i < 60; i++) {
        s.updateSetupView(_sideLeftPose());
      }
      final analyzerBeforeFlip = s.formAnalyzer;
      _drive(s, _frontPose(), kViewRedetectHysteresisFrames + 2);
      expect(s.lockedView, CurlCameraView.front);
      // Same analyzer instance — strategy never swapped it.
      expect(identical(s.formAnalyzer, analyzerBeforeFlip), isTrue);
    });
  });
}
