/// Tests for the side-view curl form analyzer.
///
/// Covers the torso-perpendicular elbow-drift metric introduced in plan
/// `federated-tickling-sunset` PR 2 — replaces the prior screen-X-shift
/// metric with `(E − S) · n̂` where `n̂ = (−u_y, u_x)` is the unit
/// perpendicular to the torso vector. Lean-invariant by construction.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
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

  group('shoulderArc detection', () {
    test('shoulder stays at baseline → no shoulderArc', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      expect(a.evaluate(ref), isNot(contains(FormError.shoulderArc)));
    });

    test('shoulder shifts 0.12 laterally → fires shoulderArc', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // relX_curr=0.12, dy=0 → disp=0.12, torsoLen=0.40, ratio=0.30 > 0.25
      final evaluated = buildSidePose(
        shoulderX: 0.62,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.62,
        elbowY: 0.50,
      );
      expect(a.evaluate(evaluated), contains(FormError.shoulderArc));
    });

    test(
      'elbow drifts but shoulder stays fixed → shoulderArc absent, elbowDrift present',
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
        // elbowX shifts far past kDriftThreshold but shoulder/hip unchanged
        final evaluated = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.62,
          elbowY: 0.50,
        );
        final errors = a.evaluate(evaluated);
        expect(errors, isNot(contains(FormError.shoulderArc)));
        expect(errors, contains(FormError.elbowDrift));
      },
    );
  });

  group('shoulderShrug detection', () {
    test('shoulder Y unchanged → no shoulderShrug', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      expect(a.evaluate(ref), isNot(contains(FormError.shoulderShrug)));
    });

    test('shoulder rises by 0.128 screen units → fires shoulderShrug', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // 2× threshold: ratio=0.32 → Δ=0.32×0.40=0.128 → shoulderY = 0.30−0.128 = 0.172
      // relY_curr = 0.172−0.70 = −0.528, dy = −0.528−(−0.40) = −0.128
      // shrugValue = 0.128, ratio = 0.128/0.40 = 0.32 > 0.16
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.172,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      expect(a.evaluate(evaluated), contains(FormError.shoulderShrug));
    });

    test('shoulder drops (negative shrugValue) → no shoulderShrug', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // shoulderY increases (moves down in screen space) → shrugValue negative → no flag
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.42,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      expect(a.evaluate(evaluated), isNot(contains(FormError.shoulderShrug)));
    });
  });

  group('backLean detection', () {
    // Use a slightly forward-tilted baseline (shoulder.x=0.55) so the
    // baseline angle sits away from the ±180° branch-cut of atan2.
    test('facing right + forward lean (shoulder moves right) → no backLean', () {
      // nose.x (0.70) > shoulder.x (0.55) → _facingRight = true
      final ref = buildSidePose(
        shoulderX: 0.55,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.55,
        elbowY: 0.50,
        noseX: 0.70,
      );
      a.onRepStart(ref);
      // shoulder moves right → forward lean for a right-facing user → backLeanDeg < 0
      final evaluated = buildSidePose(
        shoulderX: 0.65,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.65,
        elbowY: 0.50,
        noseX: 0.70,
      );
      expect(a.evaluate(evaluated), isNot(contains(FormError.backLean)));
    });

    test(
      'facing right + backward lean (shoulder moves left) → fires backLean',
      () {
        final ref = buildSidePose(
          shoulderX: 0.55,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.55,
          elbowY: 0.50,
          noseX: 0.70,
        );
        a.onRepStart(ref);
        // Large leftward shift → backward lean → backLeanDeg > 10°
        final evaluated = buildSidePose(
          shoulderX: 0.35,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.35,
          elbowY: 0.50,
          noseX: 0.70,
        );
        expect(a.evaluate(evaluated), contains(FormError.backLean));
      },
    );

    test('facing left + shoulder moves right → fires backLean', () {
      // nose.x (0.30) < shoulder.x (0.55) → _facingRight = false
      final ref = buildSidePose(
        shoulderX: 0.55,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.55,
        elbowY: 0.50,
        noseX: 0.30,
      );
      a.onRepStart(ref);
      // Large rightward shift → backward lean for left-facing → backLeanDeg > 10°
      final evaluated = buildSidePose(
        shoulderX: 0.75,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.75,
        elbowY: 0.50,
        noseX: 0.30,
      );
      expect(a.evaluate(evaluated), contains(FormError.backLean));
    });

    test('reset() clears _baselineTorsoAngleSigned and _facingRight', () {
      final ref = buildSidePose(
        shoulderX: 0.55,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.55,
        elbowY: 0.50,
        noseX: 0.70,
      );
      a.onRepStart(ref);
      // Confirm the flag fires before reset.
      final leaned = buildSidePose(
        shoulderX: 0.35,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.35,
        elbowY: 0.50,
        noseX: 0.70,
      );
      expect(a.evaluate(leaned), contains(FormError.backLean));

      // After reset, re-start with the same ref and evaluate the same pose —
      // baseline is freshly snapshotted so delta is zero → no backLean.
      a.reset();
      a.onRepStart(ref);
      expect(a.evaluate(ref), isNot(contains(FormError.backLean)));
    });
  });

  group('elbowRise detection', () {
    test('elbow stays at baseline y → no elbowRise', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      expect(a.evaluate(ref), isNot(contains(FormError.elbowRise)));
    });

    test('elbow rises by 0.144 screen units → fires elbowRise', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // baselineElbowRelY = 0.50 − 0.30 = 0.20
      // 2× threshold: rise=0.36 → Δ=0.36×0.40=0.144 → elbowY = 0.50−0.144 = 0.356
      // currentElbowRelY = 0.356−0.30 = 0.056, rise=(0.20−0.056)/0.40 = 0.36 > 0.18
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.356,
      );
      expect(a.evaluate(evaluated), contains(FormError.elbowRise));
    });

    test('elbow drops below baseline → no elbowRise', () {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // elbowY increases (elbow moves down) → rise negative → no flag
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.62,
      );
      expect(a.evaluate(evaluated), isNot(contains(FormError.elbowRise)));
    });
  });

  group('quality score — side-view', () {
    test('clean rep scores 1.0', () async {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // Wait past kMinConcentricSec (0.3 s) so concentric is in-spec.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      a.evaluate(ref);
      a.onPeakReached();
      a.onEccentricStart();
      // Wait past kMinEccentricSec (0.8 s) so eccentric is in-spec.
      await Future<void>.delayed(const Duration(milliseconds: 900));
      a.onRepEnd();
      expect(a.lastRepQuality, closeTo(1.0, 1e-9));
    });

    test(
      'shoulderShrug above threshold → fires deduction, score < 1.0',
      () async {
        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        // shoulder rises by 0.128 → shrug ratio > kShrugThreshold (0.16).
        // torsoLen in the shrug pose = hipY − shoulderY = 0.70 − 0.172 = 0.528,
        // so ratio = 0.128 / 0.528 ≈ 0.242. severity = (0.242−0.16)/0.16 ≈ 0.515.
        // deduction = 0.515 × kQualityShrugMaxDeduction (0.15) ≈ 0.077.
        // Expected score (no concentric/eccentric ding) ≈ 0.923.
        final shrugPose = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.172,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        a.evaluate(shrugPose);
        a.onPeakReached();
        a.onRepEnd();
        // Score must be strictly below 1.0 (deduction applied) and above 0.0.
        expect(a.lastRepQuality, lessThan(1.0));
        expect(a.lastRepQuality, greaterThan(0.0));
      },
    );

    test('elbowRise at 2× threshold → score 0.85', () async {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      // Shoulder.y stays 0.30 → torsoLen_curr = 0.40 (unchanged).
      // baselineElbowRelY = 0.20. currentElbowRelY = 0.356 − 0.30 = 0.056.
      // rise = (0.20 − 0.056) / 0.40 = 0.36 = 2× kElbowRiseThreshold (0.18).
      // severity = 1.0, deduction = 1.0 × 0.15 = 0.15. Score = 1.0 − 0.15 = 0.85.
      final risePose = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.356,
      );
      a.onRepStart(ref);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      a.evaluate(risePose);
      a.onPeakReached();
      a.onRepEnd();
      expect(a.lastRepQuality, closeTo(0.85, 1e-9));
    });

    test('stacked deductions clamp to 0.0 lower bound', () async {
      // Drive every deduction at once: shrug + elbowRise + lateral swing
      // + elbowDrift + shoulderArc.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      // Shoulder rises (shrug) AND shifts laterally (shoulderArc) AND elbow
      // drifts perpendicularly (elbowDrift) AND elbow rises — all at or above
      // their respective thresholds.
      final worstPose = buildSidePose(
        shoulderX: 0.62,
        shoulderY: 0.172,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.30,
        elbowY: 0.356,
      );
      a.onRepStart(ref);
      a.evaluate(worstPose);
      a.onPeakReached();
      a.onRepEnd();
      expect(a.lastRepQuality, greaterThanOrEqualTo(0.0));
      expect(a.lastRepQuality, lessThanOrEqualTo(1.0));
    });
  });

  group('fatigue detection — side view', () {
    test(
      'emits fatigue once when last 3 reps average > 1.4× first 3 average',
      () async {
        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        for (var i = 0; i < kFatigueMinReps; i++) {
          a.onRepStart(ref);
          final ms = i < 3 ? 20 : 60; // lastAvg/firstAvg ≈ 3.0 > 1.4
          await Future<void>.delayed(Duration(milliseconds: ms));
          a.onPeakReached();
          a.onEccentricStart();
          a.onRepEnd();
        }
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
        expect(a.fatigueDetected, isTrue);
      },
    );

    test('reset() clears fatigueDetected', () async {
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      for (var i = 0; i < kFatigueMinReps; i++) {
        a.onRepStart(ref);
        final ms = i < 3 ? 20 : 60;
        await Future<void>.delayed(Duration(milliseconds: ms));
        a.onPeakReached();
        a.onEccentricStart();
        a.onRepEnd();
      }
      a.consumeCompletionErrors(); // drain so fatigue fires
      expect(a.fatigueDetected, isTrue);
      a.reset();
      expect(a.fatigueDetected, isFalse);
    });
  });
}
