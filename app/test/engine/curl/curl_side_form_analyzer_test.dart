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

/// Drive [frameCount] identical [frame] poses through [a] and return the
/// LAST frame's `evaluate()` errors.
///
/// `elbowDrift` is an INSTANTANEOUS per-frame error as of 2026-05-21 —
/// every `evaluate()` call on an off-line frame returns it directly; there
/// is no rep-commit verdict and no sustained-frame gate. This helper feeds
/// identical frames so a geometry's verdict is unambiguous, then returns
/// the per-frame errors of the final frame. [onRepStart] must have run
/// already.
///
/// (Historical note: this helper used to be `driveAndCommit` and returned
/// `consumeCompletionErrors()` because `elbowDrift` was briefly a per-rep
/// sustained-frame verdict, 2026-05-16 → 2026-05-21.)
List<FormError> driveFramesLastErrors(
  CurlSideFormAnalyzer a,
  PoseResult frame, {
  int frameCount = 8,
}) {
  var last = <FormError>[];
  for (var i = 0; i < frameCount; i++) {
    last = a.evaluate(frame);
  }
  return last;
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
      // Drive a full rep: the elbow sits exactly on the leaned torso axis
      // every frame → perpendicular offset is zero → `evaluate()` must not
      // return elbowDrift on any frame (per-frame doctrine, 2026-05-21).
      for (var i = 0; i < 8; i++) {
        expect(
          a.evaluate(leaned),
          isNot(contains(FormError.elbowDrift)),
          reason:
              'elbow pinned to the torso axis has zero perpendicular '
              'offset — the per-frame elbowDrift gate must stay silent',
        );
      }
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
      // 0.10 / 0.40 = 0.25 > kDriftThreshold (now 0.15).
      final drifted = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.60,
        elbowY: 0.50,
      );
      // Per-frame contract: an off-line elbow fires `elbowDrift` on every
      // frame `evaluate()` sees it past the dead-band + threshold.
      expect(driveFramesLastErrors(a, drifted), contains(FormError.elbowDrift));
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
      expect(driveFramesLastErrors(a, drifted), contains(FormError.elbowDrift));
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
        // The dual-gate compares |ratio|, so a negative offset fires the
        // per-frame elbowDrift cue exactly like a positive one.
        final negDrift = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.40,
          elbowY: 0.50,
        );
        expect(
          driveFramesLastErrors(a, negDrift),
          contains(FormError.elbowDrift),
        );
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
        // The torso-vector guard short-circuits before the per-frame
        // elbowDrift gate runs, so no collapsed frame ever fires the cue
        // and the signed ratio is never set.
        final errs = a.evaluate(collapsed);
        expect(errs, isNot(contains(FormError.elbowDrift)));
        expect(
          driveFramesLastErrors(a, collapsed, frameCount: 7),
          isNot(contains(FormError.elbowDrift)),
        );
        expect(a.lastSignedElbowDriftRatio, isNull);
      },
    );

    test('backward elbow drift (negative signedRatio) fires elbowDrift with '
        'the same coverage as the mirrored forward drift (2026-05-21 '
        'asymmetric-occlusion fix)', () {
      // Vertical torso (S above H) → n̂ = (+1, 0); signedRatio collapses to
      // (elbowX − shoulderX) / torsoLen. Drift magnitude 0.10 / 0.40 = 0.25
      // — clear of the 0.15 threshold + 0.08 dead-band.
      //
      // Pre-2026-05-21 the elbow lookup used `kMinLandmarkConfidence` (0.4)
      // for BOTH directions; in practice ML Kit elbow confidence drops
      // below 0.4 more often on backward drift (the curling bicep occludes
      // the elbow). This test mirrors that asymmetric-confidence reality:
      // identical magnitude on both sides, but the backward elbow's
      // confidence is 0.30 — between the new `kCurlDriftElbowMinConfidence`
      // (0.25) and the old `kMinLandmarkConfidence` (0.40). The forward
      // case uses 0.9. Post-fix BOTH fire and the per-rep magnitude peaks
      // identically.
      PoseResult buildAt({required double elbowX, required double elbowConf}) {
        return PoseResult(
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
            PoseLandmark(
              type: LM.leftElbow,
              x: elbowX,
              y: 0.50,
              confidence: elbowConf,
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
          ],
        );
      }

      // Forward drift: elbow at +0.10 from shoulder, high confidence.
      final ref = buildAt(elbowX: 0.50, elbowConf: 0.9);
      a.reset();
      a.setView(CurlCameraView.sideLeft);
      a.onRepStart(ref);
      final forwardDrift = buildAt(elbowX: 0.60, elbowConf: 0.9);
      final forwardErrors = a.evaluate(forwardDrift);
      final forwardMaxRatio = a.maxElbowDriftRatioThisRep;
      final forwardSignedAtMax = a.signedElbowDriftRatioAtMax;
      expect(forwardErrors, contains(FormError.elbowDrift));
      expect(forwardSignedAtMax, isPositive);
      expect(forwardMaxRatio, closeTo(0.25, 0.01));

      // Backward drift: elbow at −0.10, occluded confidence 0.30 — between
      // the relaxed gate (0.25) and the strict engine gate (0.40). Pre-fix
      // this frame was gated OUT entirely; post-fix it fires per-frame.
      final ref2 = buildAt(elbowX: 0.50, elbowConf: 0.9);
      a.reset();
      a.setView(CurlCameraView.sideLeft);
      a.onRepStart(ref2);
      final backwardDrift = buildAt(elbowX: 0.40, elbowConf: 0.30);
      final backwardErrors = a.evaluate(backwardDrift);
      final backwardMaxRatio = a.maxElbowDriftRatioThisRep;
      final backwardSignedAtMax = a.signedElbowDriftRatioAtMax;
      expect(
        backwardErrors,
        contains(FormError.elbowDrift),
        reason:
            'Backward drift at confidence ≥ kCurlDriftElbowMinConfidence '
            '(0.25) must fire elbowDrift identically to the forward case. '
            'Pre-fix the strict 0.40 gate dropped these frames silently.',
      );
      expect(
        backwardSignedAtMax,
        isNegative,
        reason: 'Sign convention must preserve direction at the peak frame.',
      );
      expect(
        backwardMaxRatio,
        closeTo(forwardMaxRatio, 0.001),
        reason:
            'Symmetric-coverage invariant: identical-magnitude forward and '
            'backward drift must produce identical `_maxDriftRatio` once '
            'the elbow-specific relaxed gate admits the backward frames.',
      );
    });

    test('elbow below the relaxed gate (conf < 0.25) still drops out — '
        'the gate did not collapse entirely', () {
      // Regression guard: the 2026-05-21 fix lowered the elbow visibility
      // floor from 0.40 to 0.25 for the drift detector. It must NOT
      // collapse to 0 — frames where ML Kit returned no real positional
      // evidence (confidence ~ 0.10) must still be ignored so the drift
      // detector isn't poisoned by skeleton-prior guesses.
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
      final tooLow = PoseResult(
        inferenceTime: const Duration(milliseconds: 10),
        landmarks: const [
          PoseLandmark(type: LM.nose, x: 0.50, y: 0.20, confidence: 0.9),
          PoseLandmark(
            type: LM.leftShoulder,
            x: 0.50,
            y: 0.30,
            confidence: 0.9,
          ),
          PoseLandmark(type: LM.leftHip, x: 0.50, y: 0.70, confidence: 0.9),
          PoseLandmark(
            type: LM.leftElbow,
            x: 0.40,
            y: 0.50,
            confidence: 0.10, // below kCurlDriftElbowMinConfidence (0.25)
          ),
          PoseLandmark(
            type: LM.rightShoulder,
            x: 0.60,
            y: 0.30,
            confidence: 0.9,
          ),
          PoseLandmark(type: LM.rightHip, x: 0.60, y: 0.70, confidence: 0.9),
        ],
      );
      expect(a.evaluate(tooLow), isNot(contains(FormError.elbowDrift)));
      expect(a.lastSignedElbowDriftRatio, isNull);
    });

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

      // Same pose but mark the left elbow as very low confidence (0.05) —
      // gated out by `kCurlDriftElbowMinConfidence` (0.25, the relaxed
      // elbow-drift floor). Build manually since the helper forces high
      // confidence on every landmark.
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
      // Elbow gated out → drift block never runs → no per-frame fire on
      // any frame, signed ratio never set.
      final errs = a.evaluate(missingElbow);
      expect(errs, isNot(contains(FormError.elbowDrift)));
      expect(
        driveFramesLastErrors(a, missingElbow, frameCount: 7),
        isNot(contains(FormError.elbowDrift)),
      );
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
        expect(
          driveFramesLastErrors(a, drifted),
          contains(FormError.elbowDrift),
        );
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
        expect(
          driveFramesLastErrors(a, drifted),
          contains(FormError.elbowDrift),
        );
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

  group('shoulderArc detection (X-only rotation metric, post-2026-05-21)', () {
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

    test('pure rotation: shoulder shifts 0.12 in X with Y unchanged → '
        'fires shoulderArc', () {
      // Pure hip-pivot rotation: the shoulder swings horizontally relative
      // to the hip while the hip itself stays put and Y doesn't drift.
      // |dx|=0.12, torsoLen=0.40, ratio=0.30 > kSwingThreshold=0.25.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
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
      'pure forward sagittal lean: shoulder moves in Y (and a little X) '
      '→ shoulderArc must NOT fire (regression for 2026-05-21 user report)',
      () {
        // A ~15° forward sagittal lean tips the torso forward: the shoulder
        // descends in Y (relY grows) and shifts slightly in X. Pre-fix this
        // hit the Euclidean magnitude metric and false-fired "Stop rotating"
        // even though the user was leaning, not rotating. Post-fix only the
        // X component is consulted, so the small relX delta stays well below
        // kSwingThreshold=0.25.
        //
        // Geometry: shoulder pitches forward — relX moves from 0 to ~0.04
        // (well below threshold); relY moves from −0.40 to ~−0.39 (slight
        // shortening — would have *amplified* the old Euclidean metric).
        final ref = buildSidePose(
          shoulderX: 0.50,
          shoulderY: 0.30,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        a.onRepStart(ref);
        final leaned = buildSidePose(
          shoulderX: 0.54, // +0.04 → ratio ≈ 0.10, below 0.25
          shoulderY: 0.31,
          hipX: 0.50,
          hipY: 0.70,
          elbowX: 0.50,
          elbowY: 0.50,
        );
        expect(
          a.evaluate(leaned),
          isNot(contains(FormError.shoulderArc)),
          reason:
              'Pure forward lean must not produce a rotation cue — geometry '
              'fix for the 2026-05-21 user report.',
        );
      },
    );

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
        // Both `shoulderArc` and `elbowDrift` are per-frame errors. This
        // frame moves only the elbow (shoulder/hip fixed), so the very
        // first `evaluate()` must carry `elbowDrift` and must NOT carry
        // `shoulderArc` — the two detectors are orthogonal.
        final frameErrors = a.evaluate(evaluated);
        expect(frameErrors, isNot(contains(FormError.shoulderArc)));
        expect(frameErrors, contains(FormError.elbowDrift));
      },
    );
  });

  group('depthSwing detection — forward sagittal lean (post-2026-05-21)', () {
    test('pure ~15° forward lean fires depthSwing AND NOT shoulderArc AND '
        'NOT torsoSwing (user 2026-05-21 regression case)', () {
      // The exact scenario the user reported: torso tips forward by ~15°,
      // nothing else changes. Pre-fix the user heard either "Stop rotating"
      // (shoulderArc, Euclidean magnitude crossed the 0.25 ratio) or "No
      // swinging" (the lateral-X swing leg of torsoSwing) depending on
      // geometry — both wrong. Post-fix:
      //
      //   - depthSwing fires (correct cue: "Don't rock forward")
      //   - shoulderArc stays silent (X-only metric — relX delta is small)
      //   - torsoSwing is no longer emitted by the side analyzer at all
      //
      // Geometry note: this uses a contrived torso angle where the
      // shoulder lateral shift represents the projection of the lean onto
      // screen-X. The trunk-from-vertical angle delta is what depthSwing
      // gates on, so we engineer the relX / relY deltas to keep the angle
      // above kTorsoLeanThresholdDeg (12°) while keeping the relX shift
      // under the swing threshold (0.25 × torsoLen).
      //
      // Vertical reference (trunk angle 0°): shoulder directly above hip.
      // Leaned ~15° forward: shoulder.x − hip.x = 0.40 × sin(15°) ≈ 0.10,
      // shoulder.y stays roughly the same horizontal level (tiny Y change
      // is the cos(15°) shortening — about 1.4% of torsoLen).
      // relX/torsoLen ratio ≈ 0.10/0.40 = 0.25 — right at the boundary;
      // bump the lean to ~20° so the depthSwing detector fires comfortably
      // and the shoulderArc ratio is just over 0.25 too — this is the
      // unfavorable case for the X-only metric, but the post-fix shoulder
      // arc cue still fires here because the X shift IS large at 20°. So
      // pick 14° instead: enough to trip lean (12° threshold) but ratio
      // ≈ 0.24 stays just under the rotation threshold.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      // 14° lean: relX = 0.40 × sin(14°) ≈ 0.0967 → ratio ≈ 0.242 < 0.25.
      // Trunk-from-vertical angle delta ≈ 14° > kTorsoLeanThresholdDeg.
      final leaned = buildSidePose(
        shoulderX: 0.5967,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.5967,
        elbowY: 0.50,
      );
      final errors = a.evaluate(leaned);
      expect(
        errors,
        contains(FormError.depthSwing),
        reason: 'Forward lean ≥ kTorsoLeanThresholdDeg must fire depthSwing.',
      );
      expect(
        errors,
        isNot(contains(FormError.shoulderArc)),
        reason:
            'X-only rotation metric must keep "Stop rotating" silent when '
            'the X shift is below kSwingThreshold. Regression for the '
            'user-reported 2026-05-21 false positive.',
      );
      expect(
        errors,
        isNot(contains(FormError.torsoSwing)),
        reason:
            'torsoSwing is no longer emitted by the side analyzer — the '
            'lateral leg was deleted 2026-05-21 because lateral momentum is '
            'unobservable in 2D side view.',
      );
    });

    test('side analyzer never emits torsoSwing on any frame, even when the '
        'lateral X shift would have crossed the legacy threshold', () {
      // Pure horizontal shoulder displacement large enough that the old
      // `horizontalShift / torsoLen` would have fired torsoSwing. Post-fix
      // this same geometry instead trips shoulderArc (X-only rotation).
      // The cue the user actually hears is "Stop rotating" — correct in
      // side view, because a pure lateral shoulder X shift IS a hip-pivot
      // rotation here (the user's lateral axis lives in screen depth).
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      a.onRepStart(ref);
      final shifted = buildSidePose(
        shoulderX: 0.65, // 0.15 / 0.40 = 0.375 ratio, well above 0.25
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.65,
        elbowY: 0.50,
      );
      final errors = a.evaluate(shifted);
      expect(errors, isNot(contains(FormError.torsoSwing)));
      expect(errors, contains(FormError.shoulderArc));
    });
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

    test('stacked deductions clamp to 0.0 lower bound', () async {
      // Drive every deduction at once: shrug + lateral swing + elbowDrift
      // + shoulderArc.
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

  // ── Per-frame elbow-drift fire (instantaneous doctrine, 2026-05-21) ──
  //
  // `elbowDrift` is an INSTANTANEOUS per-frame error: `evaluate()` adds it
  // to the returned list on every frame whose torso-perpendicular elbow-
  // offset ratio clears BOTH the effective dead-band AND the audit
  // threshold. There is no rep-commit verdict and no sustained-frame gate
  // — the user hears the cue for as long as the elbow is off the torso
  // line and it stops the moment the elbow returns. The TTS cooldown +
  // verbosity cap (host layer) and the per-frame dead-band do the
  // throttling. This replaced the 2026-05-16 sustained-frame per-rep
  // verdict.
  group('per-frame elbow-drift fire — instantaneous doctrine', () {
    // Clean reference: shoulder over hip, elbow on the torso axis.
    PoseResult cleanRef() => buildSidePose(
      shoulderX: 0.50,
      shoulderY: 0.30,
      hipX: 0.50,
      hipY: 0.70,
      elbowX: 0.50,
      elbowY: 0.50,
    );

    // Upright torso → n̂ = (+1, 0); perpendicular ratio = (elbowX − 0.50)
    // / 0.40. `elbowX` 0.60 → ratio 0.25 (well over the 0.15 threshold).
    PoseResult offLineFrame({double elbowX = 0.60}) => buildSidePose(
      shoulderX: 0.50,
      shoulderY: 0.30,
      hipX: 0.50,
      hipY: 0.70,
      elbowX: elbowX,
      elbowY: 0.50,
    );

    test('a single off-line frame fires elbowDrift immediately', () {
      a.onRepStart(cleanRef());
      expect(
        a.evaluate(offLineFrame()),
        contains(FormError.elbowDrift),
        reason:
            'Per-frame doctrine: any frame past dead-band + threshold '
            'fires the cue on that frame, with no sustained-frame wait.',
      );
    });

    test('a clean frame does NOT fire elbowDrift', () {
      a.onRepStart(cleanRef());
      expect(
        a.evaluate(cleanRef()),
        isNot(contains(FormError.elbowDrift)),
        reason: 'elbow on the torso axis → silent.',
      );
    });

    test('the cue stops the moment the elbow returns to the torso line', () {
      a.onRepStart(cleanRef());
      // Drift off-line: fires.
      expect(a.evaluate(offLineFrame()), contains(FormError.elbowDrift));
      // Snap back onto the torso axis: must go silent on the very next
      // frame — no lingering verdict, no rep-commit echo.
      expect(
        a.evaluate(cleanRef()),
        isNot(contains(FormError.elbowDrift)),
        reason:
            'Returning the elbow to the torso line silences the cue '
            'immediately — that is the whole point of the per-frame model.',
      );
    });

    test('re-arms automatically: drift → recover → drift again each fires', () {
      a.onRepStart(cleanRef());
      // Episode 1.
      expect(a.evaluate(offLineFrame()), contains(FormError.elbowDrift));
      // Recover.
      expect(a.evaluate(cleanRef()), isNot(contains(FormError.elbowDrift)));
      // Episode 2 — a fresh drift after recovery fires again. The cue gate
      // has no memory; only the host-layer TTS cooldown throttles the
      // spoken cadence.
      expect(
        a.evaluate(offLineFrame()),
        contains(FormError.elbowDrift),
        reason:
            'A second drift episode after the elbow recovered must fire '
            'again — the per-frame gate re-arms with no hysteresis.',
      );
    });

    test('elbowDrift is NOT emitted from consumeCompletionErrors', () {
      a.onRepStart(cleanRef());
      // Drive a full rep of off-line frames — every evaluate() fired the
      // cue, but the rep-commit boundary must NOT add another elbowDrift.
      for (var i = 0; i < 8; i++) {
        expect(a.evaluate(offLineFrame()), contains(FormError.elbowDrift));
      }
      expect(
        a.consumeCompletionErrors(),
        isNot(contains(FormError.elbowDrift)),
        reason:
            'The rep-commit verdict path was removed 2026-05-21 — '
            'elbowDrift is purely per-frame now.',
      );
    });

    test('a too-short rep (1 frame off-line) still fires per frame — '
        'no min-frame floor anymore', () {
      a.onRepStart(cleanRef());
      // The deleted sustained-frame gate failed OPEN below 6 frames. The
      // per-frame model has no floor: even a 1-frame rep fires if that
      // frame is off-line.
      expect(a.evaluate(offLineFrame()), contains(FormError.elbowDrift));
    });

    test('ratio 0.175 (above the 0.15 audit threshold + 0.08 dead-band) '
        'fires on the frame', () {
      a.onRepStart(cleanRef());
      // Upright torso, torsoLen 0.40 → elbowX offset 0.07 → ratio 0.175.
      expect(
        a.evaluate(offLineFrame(elbowX: 0.57)),
        contains(FormError.elbowDrift),
      );
    });

    test('ratio between dead-band and the threshold (0.12) does NOT fire '
        '— minimal-movement budget preserved', () {
      a.onRepStart(cleanRef());
      // elbowX 0.548 → ratio 0.12: above the 0.08 dead-band but below the
      // 0.15 audit threshold. The dual-gate requires BOTH — this is the
      // user's silent movement budget.
      expect(
        a.evaluate(offLineFrame(elbowX: 0.548)),
        isNot(contains(FormError.elbowDrift)),
      );
    });

    test('per-rep state cleared on onRepStart — rep 2 not contaminated', () {
      // Rep 1: off-line, fires per frame.
      a.onRepStart(cleanRef());
      expect(a.evaluate(offLineFrame()), contains(FormError.elbowDrift));
      a.consumeCompletionErrors();
      a.onRepEnd();
      // Rep 2: clean — must be silent. No per-rep state survives onRepStart.
      a.onRepStart(cleanRef());
      expect(
        a.evaluate(cleanRef()),
        isNot(contains(FormError.elbowDrift)),
        reason: 'onRepStart clears all per-rep drift state.',
      );
    });

    test('reset() clears per-rep drift state', () {
      a.onRepStart(cleanRef());
      a.evaluate(offLineFrame());
      a.reset();
      a.setView(CurlCameraView.sideLeft);
      // A fresh clean rep after reset must be silent.
      a.onRepStart(cleanRef());
      expect(a.evaluate(cleanRef()), isNot(contains(FormError.elbowDrift)));
    });
  });
}
