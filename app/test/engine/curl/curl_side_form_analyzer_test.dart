/// Tests for the side-view curl form analyzer.
///
/// Covers the torso-perpendicular elbow-drift metric introduced in plan
/// `federated-tickling-sunset` PR 2 — replaces the prior screen-X-shift
/// metric with `(E − S) · n̂` where `n̂ = (−u_y, u_x)` is the unit
/// perpendicular to the torso vector. Lean-invariant by construction.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_side_form_analyzer.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

/// Build a side-view pose with explicit shoulder / hip / elbow positions
/// for the LEFT side (the analyzer defaults to `sideLeft`).
///
/// Provides the right-side mirrors at the same y but offscreen so the
/// confidence gate keeps them out of any accidental left/right ambiguity.
PoseResult buildSidePose({
  required double shoulderX,
  required double shoulderY,
  required double hipX,
  required double hipY,
  required double elbowX,
  required double elbowY,
  double noseX = 0.50,
  double noseY = 0.20,
  double confidence = 0.9,
}) {
  PoseLandmark lm(int type, double x, double y) =>
      PoseLandmark(type: type, x: x, y: y, confidence: confidence);
  return PoseResult(
    inferenceTime: const Duration(milliseconds: 10),
    landmarks: [
      lm(LM.nose, noseX, noseY),
      lm(LM.leftShoulder, shoulderX, shoulderY),
      lm(LM.leftHip, hipX, hipY),
      lm(LM.leftElbow, elbowX, elbowY),
      // Right side present so torso-len fallbacks work, but off the
      // visible side and not used by the sideLeft code path.
      lm(LM.rightShoulder, shoulderX + 0.1, shoulderY),
      lm(LM.rightHip, hipX + 0.1, hipY),
      lm(LM.rightElbow, elbowX + 0.1, elbowY),
    ],
  );
}

void main() {
  late CurlSideFormAnalyzer a;

  setUp(() {
    a = CurlSideFormAnalyzer()..setView(CurlCameraView.sideLeft);
  });

  group('lean invariance — torso-perpendicular projection', () {
    test('forward-leaning torso with elbow pinned to torso axis does NOT '
        'fire elbowDrift', () {
      // Upright reference: shoulder directly above hip; elbow on the
      // torso axis (same x as shoulder).
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);

      // Forward lean: shoulder shifts +0.10 on x but hip stays put —
      // torso vector now points down-and-forward. Move the elbow with
      // the torso so it stays pinned to the torso axis (i.e. on the
      // line from S to H — perpendicular offset = 0).
      final leaned = buildSidePose(
        shoulderX: 0.60,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.55, // halfway between S and H — exactly on the axis
        elbowY: 0.50,
      );
      expect(
        a.evaluate(leaned),
        isNot(contains(FormError.elbowDrift)),
        reason:
            'elbow on the leaned torso axis must register zero '
            'perpendicular offset',
      );
      // Sanity: signed ratio rounded to ~0 (modulo float noise).
      expect(a.lastSignedElbowDriftRatio, isNotNull);
      expect(a.lastSignedElbowDriftRatio!.abs(), lessThan(1e-9));
    });

    test('upright torso with 30%-perpendicular elbow offset DOES fire '
        'elbowDrift', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);

      // Upright torso: torso vector is (0, −0.40), so n̂ = (+1, 0) —
      // perpendicular offset is exactly the elbow's x − shoulder.x.
      // 0.10 / 0.40 = 0.25 > kDriftThreshold (0.20).
      final drifted = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.60,
        elbowY: 0.50,
      );
      expect(a.evaluate(drifted), contains(FormError.elbowDrift));
    });

    test('forward-leaning torso AND off-axis elbow DOES fire elbowDrift '
        '(true positive under the confound)', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);

      // Lean forward (shoulder.x = 0.60, hip.x = 0.50) AND offset elbow
      // by 0.10 on the perpendicular direction. Torso u = (0.10, −0.40)
      // → |u| ≈ 0.4123, n̂ ≈ (+0.970, +0.243). Pick elbow such that
      // (elbow − shoulder) · n̂ / |u| > kDriftThreshold (0.20).
      // With elbow at (0.70, 0.45): (0.10, +0.15) · (0.970, 0.243) /
      // 0.4123 ≈ (0.097 + 0.0365) / 0.4123 ≈ 0.324 > 0.20.
      final drifted = buildSidePose(
        shoulderX: 0.60,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.70,
        elbowY: 0.45,
      );
      expect(a.evaluate(drifted), contains(FormError.elbowDrift));
    });
  });

  group('signed elbow-drift ratio + telemetry lifecycle', () {
    test('positive perpendicular offset → lastSignedElbowDriftRatio > 0', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // n̂ = (+1, 0). Elbow at +0.10 → signedRatio ≈ +0.25.
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      expect(a.lastSignedElbowDriftRatio, isNotNull);
      expect(a.lastSignedElbowDriftRatio, greaterThan(0));
    });

    test('negative perpendicular offset → lastSignedElbowDriftRatio < 0', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.40, // elbow on the −n̂ side
          elbowY: 0.50,
        ),
      );
      expect(a.lastSignedElbowDriftRatio, isNotNull);
      expect(a.lastSignedElbowDriftRatio, lessThan(0));
    });

    test(
      'flag uses magnitude — both signs trigger elbowDrift past threshold',
      () {
        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);

        // Elbow on the −n̂ side at the same magnitude that fires from +.
        final negDrift = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.40,
          elbowY: 0.50,
        );
        expect(a.evaluate(negDrift), contains(FormError.elbowDrift));
      },
    );

    test('onRepStart clears lastSignedElbowDriftRatio', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      expect(a.lastSignedElbowDriftRatio, isNotNull);
      a.onRepStart(ref);
      expect(a.lastSignedElbowDriftRatio, isNull);
    });

    test('reset() clears lastSignedElbowDriftRatio', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      expect(a.lastSignedElbowDriftRatio, isNotNull);
      a.reset();
      expect(a.lastSignedElbowDriftRatio, isNull);
    });
  });

  group('numerical safety', () {
    test(
      'collapsed torso (S ≈ H) → no elbowDrift, signed ratio stays null',
      () {
        // Note: must clear the signed ratio between calls, so reset before.
        a.reset();
        a.setView(CurlCameraView.sideLeft);

        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);

        // Shoulder and hip practically coincident — torsoVecLen < 0.01 and
        // the swing block also fails its own guard. Either way, the elbow
        // path should never set lastSignedElbowDriftRatio.
        final collapsed = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.500,
          hipX: 0.50,
          hipY: 0.503, // |Δ| = 0.003 < 0.01
          elbowX: 0.60,
          elbowY: 0.50,
        );
        final errs = a.evaluate(collapsed);
        expect(errs, isNot(contains(FormError.elbowDrift)));
        expect(a.lastSignedElbowDriftRatio, isNull);
      },
    );

    test('missing elbow landmark → no elbowDrift, signed ratio stays null', () {
      a.reset();
      a.setView(CurlCameraView.sideLeft);

      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);

      // Same pose but mark the left elbow as low-confidence — gated out
      // by `kMinLandmarkConfidence`. Build manually since the helper
      // forces high confidence on every landmark.
      final landmarks = <PoseLandmark>[
        const PoseLandmark(type: LM.nose, x: 0.50, y: 0.20, confidence: 0.9),
        const PoseLandmark(
          type: LM.leftShoulder,
          x: 0.50,
          y: 0.30,
          confidence: 0.9,
        ),
        const PoseLandmark(type: LM.leftHip, x: 0.50, y: 0.70, confidence: 0.9),
        const PoseLandmark(
          type: LM.leftElbow,
          x: 0.60,
          y: 0.50,
          confidence: 0.05, // below kMinLandmarkConfidence
        ),
        const PoseLandmark(
          type: LM.rightShoulder,
          x: 0.60,
          y: 0.30,
          confidence: 0.9,
        ),
        const PoseLandmark(
          type: LM.rightHip,
          x: 0.60,
          y: 0.70,
          confidence: 0.9,
        ),
      ];
      final missingElbow = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: landmarks,
      );
      final errs = a.evaluate(missingElbow);
      expect(errs, isNot(contains(FormError.elbowDrift)));
      expect(a.lastSignedElbowDriftRatio, isNull);
    });
  });

  group('arm resolution — confidence-based, ignores user-declared side', () {
    /// Pose where ONLY the right anatomical arm is visible (left landmarks
    /// at zero confidence). Mirrors what ML Kit produces when the user
    /// turns their right side to a non-mirroring back camera.
    PoseResult buildRightArmOnlyPose({
      required double shoulderX,
      required double shoulderY,
      required double hipX,
      required double hipY,
      required double elbowX,
      required double elbowY,
      double noseX = 0.50,
      double noseY = 0.20,
    }) {
      return PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks:
            [
                const PoseLandmark(
                  type: LM.nose,
                  x: 0.50,
                  y: 0.20,
                  confidence: 0.9,
                ),
                // Left side: zero confidence — must be ignored by the resolver.
                const PoseLandmark(
                  type: LM.leftShoulder,
                  x: 0.0,
                  y: 0.0,
                  confidence: 0.0,
                ),
                const PoseLandmark(
                  type: LM.leftHip,
                  x: 0.0,
                  y: 0.0,
                  confidence: 0.0,
                ),
                const PoseLandmark(
                  type: LM.leftElbow,
                  x: 0.0,
                  y: 0.0,
                  confidence: 0.0,
                ),
                // Right side: high confidence, real geometry.
                PoseLandmark(
                  type: LM.rightShoulder,
                  x: shoulderX,
                  y: shoulderY,
                  confidence: 0.9,
                ),
                PoseLandmark(
                  type: LM.rightHip,
                  x: hipX,
                  y: hipY,
                  confidence: 0.9,
                ),
                PoseLandmark(
                  type: LM.rightElbow,
                  x: elbowX,
                  y: elbowY,
                  confidence: 0.9,
                ),
              ]
              ..[0] = PoseLandmark(
                type: LM.nose,
                x: noseX,
                y: noseY,
                confidence: 0.9,
              ),
      );
    }

    test(
      'declared sideLeft + only right-arm landmarks visible → tracks RIGHT arm',
      () {
        // The bug we are fixing: user picked "Left" (or the picker didn't
        // match ML Kit's labelling), but only the right anatomical arm is
        // confidence-visible. The analyzer must follow the landmarks, not
        // the declared view.
        a.setView(CurlCameraView.sideLeft);
        final ref = buildRightArmOnlyPose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);

        // Off-axis elbow on the RIGHT arm — should fire elbowDrift if
        // the analyzer correctly resolved to the right arm. (If it
        // wrongly stuck with sideLeft = left landmarks, the left
        // elbow's zero confidence would short-circuit the elbow check
        // and the test would fail with "isNot contains".)
        final drifted = buildRightArmOnlyPose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.62,
          elbowY: 0.50,
        );
        expect(a.evaluate(drifted), contains(FormError.elbowDrift));
      },
    );

    test(
      'declared sideRight + only left-arm landmarks visible → tracks LEFT arm',
      () {
        // Symmetric case. Locks the resolver's symmetry.
        a.setView(CurlCameraView.sideRight);
        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);
        // buildSidePose puts left at 0.9 and right at 0.9 too — bump up
        // a left-only variant by zeroing the right side instead.
        final drifted = PoseResult(
          inferenceTime: const Duration(milliseconds: 10),
          landmarks: [
            const PoseLandmark(
              type: LM.nose,
              x: 0.50,
              y: 0.20,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftShoulder,
              x: 0.50,
              y: 0.30,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftHip,
              x: 0.50,
              y: 0.70,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftElbow,
              x: 0.62,
              y: 0.50,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.rightShoulder,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
            const PoseLandmark(
              type: LM.rightHip,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
            const PoseLandmark(
              type: LM.rightElbow,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
          ],
        );
        // Re-run onRepStart on a left-only ref so the resolver picks left.
        final leftOnlyRef = PoseResult(
          inferenceTime: const Duration(milliseconds: 10),
          landmarks: [
            const PoseLandmark(
              type: LM.nose,
              x: 0.50,
              y: 0.20,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftShoulder,
              x: 0.50,
              y: 0.30,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftHip,
              x: 0.50,
              y: 0.70,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.leftElbow,
              x: 0.50,
              y: 0.50,
              confidence: 0.9,
            ),
            const PoseLandmark(
              type: LM.rightShoulder,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
            const PoseLandmark(
              type: LM.rightHip,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
            const PoseLandmark(
              type: LM.rightElbow,
              x: 0.0,
              y: 0.0,
              confidence: 0.0,
            ),
          ],
        );
        a.onRepStart(leftOnlyRef);
        expect(a.evaluate(drifted), contains(FormError.elbowDrift));
        // Silence the unused-fixture warning if the test setup variable
        // is otherwise unused.
        expect(ref.landmarks, isNotEmpty);
      },
    );
  });

  group('signedElbowDriftRatioAtMax — sign at peak magnitude', () {
    // The retune pipeline needs the SIGN AT THE PEAK FRAME, not the sign
    // of the most recent frame. These tests pin that semantic.

    test('captures the sign of the frame whose magnitude is highest', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);

      // Frame 1: small positive offset (+0.10 / 0.40 = +0.25 ratio).
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      // Frame 2: larger NEGATIVE offset (−0.16 / 0.40 = −0.40 ratio).
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.34,
          elbowY: 0.50,
        ),
      );
      // Frame 3: tiny positive (+0.02 / 0.40 = +0.05) — the most RECENT
      // frame. lastSignedElbowDriftRatio should follow this; the at-max
      // getter must NOT — it should still hold frame 2's negative sign
      // because frame 2 had the highest magnitude.
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.52,
          elbowY: 0.50,
        ),
      );

      expect(
        a.lastSignedElbowDriftRatio,
        greaterThan(0),
        reason: 'most recent frame had a small positive offset',
      );
      expect(
        a.signedElbowDriftRatioAtMax,
        lessThan(0),
        reason: 'peak magnitude was on frame 2 with negative sign',
      );
      expect(a.signedElbowDriftRatioAtMax!.abs(), closeTo(0.40, 1e-9));
    });

    test('onRepStart clears signedElbowDriftRatioAtMax', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      expect(a.signedElbowDriftRatioAtMax, isNotNull);
      a.onRepStart(ref);
      expect(a.signedElbowDriftRatioAtMax, isNull);
    });

    test('reset() clears signedElbowDriftRatioAtMax', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      a.evaluate(
        buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.60,
          elbowY: 0.50,
        ),
      );
      expect(a.signedElbowDriftRatioAtMax, isNotNull);
      a.reset();
      expect(a.signedElbowDriftRatioAtMax, isNull);
    });
  });
}
