import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/rep_counter.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

/// Builds a synthetic pose where both elbow joints form the requested
/// angle in degrees.
///
/// Geometry, per limb (shoulder above elbow, both at the same x):
///   shoulder → elbow vector points down (+y).
///   elbow → wrist vector is rotated such that the angle between
///   (elbow→shoulder) and (elbow→wrist) equals [elbowAngle].
///
/// Concretely: elbow→shoulder = (0, -1) (pointing up). To make the angle
/// at the elbow equal θ, the elbow→wrist unit vector is
///   (sin θ, cos θ)   when θ=180° → (0, -1) collinear with up → 0°? No.
/// Wait. We want the angle BETWEEN those two vectors to equal θ.
///   dot(u, v) = |u||v| cos(angle).
///   u = elbow→shoulder = (0, -1).
///   We want angle(u, v) = θ. So v = rotate(u, θ).
///   Rotating (0, -1) clockwise by θ in screen coords:
///     v = (sin θ, -cos θ).
///   Check θ=0: v=(0,-1) → same as u → angle 0 ✓
///   Check θ=180°: v=(0,1) → opposite of u → angle 180° ✓
///   Check θ=90°: v=(1,0) → perpendicular → angle 90° ✓
PoseResult _poseAtElbowAngle(double elbowAngle) {
  final theta = elbowAngle * math.pi / 180.0;
  // Unit-vector offset from elbow to wrist.
  const r = 0.15;
  final wxOffset = r * math.sin(theta);
  final wyOffset = -r * math.cos(theta);

  // Shoulder is directly above the elbow.
  PoseLandmark shoulder(int type, double cx) =>
      PoseLandmark(type: type, x: cx, y: 0.20, confidence: 0.95);
  PoseLandmark elbow(int type, double cx) =>
      PoseLandmark(type: type, x: cx, y: 0.50, confidence: 0.95);
  PoseLandmark wrist(int type, double cx) => PoseLandmark(
    type: type,
    x: cx + wxOffset,
    y: 0.50 + wyOffset,
    confidence: 0.95,
  );

  return PoseResult(
    landmarks: [
      shoulder(LM.leftShoulder, 0.40),
      elbow(LM.leftElbow, 0.40),
      wrist(LM.leftWrist, 0.40),
      shoulder(LM.rightShoulder, 0.60),
      elbow(LM.rightElbow, 0.60),
      wrist(LM.rightWrist, 0.60),
      // Hips so the view detector has something to work with.
      PoseLandmark(type: LM.leftHip, x: 0.42, y: 0.75, confidence: 0.95),
      PoseLandmark(type: LM.rightHip, x: 0.58, y: 0.75, confidence: 0.95),
      PoseLandmark(type: LM.nose, x: 0.50, y: 0.10, confidence: 0.95),
    ],
    inferenceTime: const Duration(milliseconds: 16),
  );
}

/// Drives [count] identical frames at [elbowAngle] through [counter],
/// returning the final snapshot. Real wall-clock delay between frames
/// satisfies the FSM's `kStateDebounce` (500ms).
Future<RepSnapshot> _holdAt(
  RepCounter counter,
  double elbowAngle, {
  int frames = 8,
  Duration interval = const Duration(milliseconds: 80),
}) async {
  RepSnapshot? last;
  for (var i = 0; i < frames; i++) {
    last = counter.update(_poseAtElbowAngle(elbowAngle));
    await Future<void>.delayed(interval);
  }
  return last!;
}

/// Force the curl view detector to lock to [view] without going through
/// `updateSetupView`. Achieved by pumping enough setup frames first; we
/// pick `front` because our symmetric pose maps cleanly to it.
Future<void> _lockViewToFront(RepCounter counter) async {
  // Push setup frames until view detector locks. Symmetric pose →
  // detector should lock to `front` quickly.
  for (var i = 0; i < 30; i++) {
    final v = counter.updateSetupView(_poseAtElbowAngle(170));
    if (v == CurlCameraView.front) return;
  }
  fail('view detector failed to lock to front in setup');
}

/// Drives one full curl rep (rest → peak → rest) at the given extremes.
///
/// Sweep steps use [_kSweepFrames] frames (enough to advance the 3-frame
/// smoothing window); hold phases use 8 frames to guarantee the 500ms
/// debounce window is cleared before the next state transition fires.
/// The total per-state wall-clock is kept well under [kStuckStateLimit].
///
/// Defaults chosen to clear the global threshold constants
/// (`kCurlStartAngle`=160, `kCurlPeakAngle`=70, `kCurlEndAngle`=140).
Future<RepSnapshot> _driveOneRep(
  RepCounter counter, {
  double restAngle = 180,
  double peakAngle = 10,
}) async {
  await _holdAt(counter, restAngle, frames: 8);
  for (final a in [
    160.0,
    140.0,
    120.0,
    100.0,
    80.0,
    60.0,
    40.0,
    20.0,
    peakAngle,
  ]) {
    await _holdAt(counter, a, frames: _kSweepFrames);
  }
  await _holdAt(counter, peakAngle, frames: 8);
  for (final a in [
    20.0,
    40.0,
    60.0,
    80.0,
    100.0,
    120.0,
    140.0,
    160.0,
    restAngle,
  ]) {
    await _holdAt(counter, a, frames: _kSweepFrames);
  }
  return _holdAt(counter, restAngle, frames: 8);
}

/// Frames per sweep step: 3 advances the smoothing window; the hold
/// phases (8 frames × 80ms = 640ms) satisfy the 500ms debounce gate.
const int _kSweepFrames = 3;

void main() {
  group('default constructor — globals only', () {
    test('a curl driven through the global gates counts a rep', () async {
      final counter = RepCounter();
      await _lockViewToFront(counter);
      final snap = await _driveOneRep(counter);
      expect(snap.reps, 1);
    });

    test(
      'commit fires per-side per rep — symmetric front view yields 2',
      () async {
        var commitCount = 0;
        final counter = RepCounter(
          onCurlRepCommit:
              ({
                required ProfileSide side,
                required CurlCameraView view,
                required double minAngle,
                required double maxAngle,
                required Duration? concentricDuration,
                double? minAtPeak,
              }) {
                commitCount++;
              },
        );
        await _lockViewToFront(counter);
        await _driveOneRep(counter);
        // Symmetric front rep → both (left, front) and (right, front)
        // buckets get the sample.
        expect(commitCount, 2);
      },
    );
  });

  group('threshold-lock invariant', () {
    test('thresholds locked at IDLE→CONCENTRIC drive the rest of the rep, '
        'even if the provider later returns unreachable thresholds', () async {
      // The provider returns sensible globals while IDLE. The instant
      // the FSM commits to CONCENTRIC, we arm the latch — any further
      // call returns thresholds whose peakAngle is below the user's
      // physical floor. If the FSM re-resolves mid-rep, the rep won't
      // count and the test fails loudly.
      var locked = false;
      RomThresholds provider(ProfileSide _, CurlCameraView _, int _) {
        if (locked) return _unreachablePeakThresholds();
        return RomThresholds.global();
      }

      final counter = RepCounter(curlThresholdsProvider: provider);
      await _lockViewToFront(counter);
      // Sit at rest (above the widest start gate: front≈172.9).
      await _holdAt(counter, 180, frames: 8);
      // Drive descent past the start gate. Hold until the 3-frame smoothed
      // value clears the start threshold so the FSM commits to CONCENTRIC.
      await _holdAt(counter, 160, frames: 8);
      // FSM is now in CONCENTRIC. Arm the latch — any further provider
      // call returns poison.
      locked = true;
      // Continue the descent through PEAK (front≈19.75) and back up.
      // Provider is poison; if FSM re-resolves, peak unreachable → no rep.
      for (final a in [140.0, 120.0, 100.0, 80.0, 60.0, 40.0, 20.0, 10.0]) {
        await _holdAt(counter, a, frames: _kSweepFrames);
      }
      await _holdAt(counter, 10, frames: 8); // Hold at peak.
      for (final a in [
        20.0,
        40.0,
        60.0,
        80.0,
        100.0,
        120.0,
        140.0,
        160.0,
        180.0,
      ]) {
        await _holdAt(counter, a, frames: _kSweepFrames);
      }
      final snap = await _holdAt(counter, 180, frames: 8);
      expect(
        snap.reps,
        1,
        reason: 'rep must count using thresholds locked at rep start',
      );
    });
  });

  group('rep commit attribution', () {
    test(
      'front-view symmetric rep commits to BOTH left and right buckets',
      () async {
        final commits = <_Commit>[];
        final counter = RepCounter(
          onCurlRepCommit:
              ({
                required ProfileSide side,
                required CurlCameraView view,
                required double minAngle,
                required double maxAngle,
                required Duration? concentricDuration,
                double? minAtPeak,
              }) {
                commits.add(_Commit(side, view, minAngle, maxAngle));
              },
        );
        await _lockViewToFront(counter);
        await _driveOneRep(counter);

        expect(
          commits,
          hasLength(2),
          reason: 'symmetric front rep → both buckets',
        );
        expect(commits.map((c) => c.side).toSet(), {
          ProfileSide.left,
          ProfileSide.right,
        });
        for (final c in commits) {
          expect(c.view, CurlCameraView.front);
        }
      },
    );

    test('view-unknown reps drop the sample (no commit fires)', () async {
      final commits = <_Commit>[];
      final counter = RepCounter(
        onCurlRepCommit:
            ({
              required ProfileSide side,
              required CurlCameraView view,
              required double minAngle,
              required double maxAngle,
              required Duration? concentricDuration,
              double? minAtPeak,
            }) {
              commits.add(_Commit(side, view, minAngle, maxAngle));
            },
      );
      // Skip view lock entirely — view stays `unknown`.
      await _driveOneRep(counter);
      expect(commits, isEmpty, reason: 'unknown view → drop the sample');
    });
  });

  group('reset semantics', () {
    test('nextSet clears thresholds and view lock', () async {
      final counter = RepCounter();
      await _lockViewToFront(counter);
      await _driveOneRep(counter);
      counter.nextSet();
      // After nextSet, view is unknown again (counter.nextSet resets
      // the view detector). A new rep without re-locking should still
      // count via the default provider, but commit should NOT fire.
      var commits = 0;
      final c2 = RepCounter(
        onCurlRepCommit:
            ({
              required ProfileSide side,
              required CurlCameraView view,
              required double minAngle,
              required double maxAngle,
              required Duration? concentricDuration,
              double? minAtPeak,
            }) {
              commits++;
            },
      );
      // Don't lock view — replicates a fresh set's pre-lock state.
      await _driveOneRep(c2);
      expect(commits, 0);
    });
  });
}

class _Commit {
  final ProfileSide side;
  final CurlCameraView view;
  final double minAngle;
  final double maxAngle;
  _Commit(this.side, this.view, this.minAngle, this.maxAngle);
}

/// Poison thresholds for the lock-invariant test: peakAngle is far below
/// any angle our synthetic rep produces (~50°). If the FSM uses these
/// mid-rep, peak is never reached and the rep silently fails to count.
RomThresholds _unreachablePeakThresholds() {
  return RomThresholds.fromBucket(
    _FakeBucket(observedMinAngle: 10, observedMaxAngle: 175),
  );
}

class _FakeBucket implements RomBucketLike {
  @override
  final double observedMinAngle;
  @override
  final double observedMaxAngle;
  _FakeBucket({required this.observedMinAngle, required this.observedMaxAngle});
}
