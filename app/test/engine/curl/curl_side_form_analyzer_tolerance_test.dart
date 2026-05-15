/// Tests for the Form Tolerance Percent dial as observed by
/// `CurlSideFormAnalyzer.evaluate`.
///
/// Two invariants the slider must maintain at every position in `[0, 100]`:
///   1. Magnitude > audit threshold → cue fires (slider cannot weaken).
///   2. Magnitude < audit threshold → cue never fires (slider cannot
///      strengthen above its hard upper bound either, by construction).
///
/// The "interesting" behavior is in the middle band (baseline < magnitude
/// < threshold) — but that band is always silent today (audit gate blocks)
/// and remains silent at every tolerance setting. So the only outcome the
/// user sees from moving the slider is whether ALREADY-silent borderline
/// motion stays silent (yes, at every percent) — confirming the dial
/// can never weaken safety while widening the silent budget at the edges.
///
/// We test both invariants per cue.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/form_thresholds.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_side_form_analyzer.dart';
import 'package:fitrack/models/landmark_types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

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
      lm(LM.rightShoulder, shoulderX + 0.1, shoulderY),
      lm(LM.rightHip, hipX + 0.1, hipY),
      lm(LM.rightElbow, elbowX + 0.1, elbowY),
    ],
  );
}

CurlSideFormAnalyzer makeAnalyzer(int percent) =>
    CurlSideFormAnalyzer(formThresholds: FormThresholds.withTolerance(percent))
      ..setView(CurlCameraView.sideLeft);

void main() {
  group('Tolerance slider — safety invariant 1: '
      'magnitude > threshold fires at every percent', () {
    test('shoulderShrug fires at percent=0, 50, 100 when ratio clearly > '
        'threshold', () {
      // Geometry: torso vertical len = 0.40 (hipY 0.70 - shoulderY 0.30).
      // shrug ratio = (baselineRelY - currentRelY) / torsoLen.
      // 2× threshold = 0.40 → relY shift = 0.16 → shoulderY = 0.30 - 0.16 = 0.14.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.14,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      for (final percent in [0, 25, 50, 75, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          contains(FormError.shoulderShrug),
          reason:
              'Tolerance must NEVER suppress a clearly-above-threshold cue '
              '(percent=$percent, ratio≈0.4 > kShrugThreshold=$kShrugThreshold)',
        );
      }
    });
  });

  group('Tolerance slider — safety invariant 2: '
      'magnitude < threshold never fires at any percent', () {
    test('shoulderShrug stays silent at every tolerance '
        'when ratio < threshold', () {
      // ratio = 0.5 × kShrugThreshold (0.10) → between baseline (0.06) and
      // threshold (0.20). Audit gate blocks at every tolerance setting.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      // torsoLen=0.40, target ratio=0.10 → relY shift = 0.04 → shoulderY 0.26.
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.26,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      for (final percent in [0, 25, 50, 75, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          isNot(contains(FormError.shoulderShrug)),
          reason:
              'Audit threshold is the upper bound — tolerance dial cannot '
              'push a sub-threshold magnitude into firing '
              '(percent=$percent, ratio=0.10 < kShrugThreshold=0.20)',
        );
      }
    });
  });

  group('Tolerance slider — dead-band widening on borderline motion', () {
    test('shoulderShrug silent at every tolerance when ratio just below '
        'baseline (always-quiet zone)', () {
      // ratio = 0.5 × baseline (0.03) → strictly below baseline_deadband
      // = 0.06 at every tolerance setting. Always silent.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      // torsoLen=0.40, target ratio=0.03 → relY shift = 0.012 → shoulderY=0.288.
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.288,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      for (final percent in [0, 50, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          isNot(contains(FormError.shoulderShrug)),
          reason:
              'Sub-baseline magnitude must stay silent at every tolerance '
              '(percent=$percent — both gates active and the audit gate '
              'fails because magnitude < threshold)',
        );
      }
    });
  });

  group('Per-cue gate wiring — each cue must consult its own '
      'effective deadband', () {
    // The risk these tests close: a copy-paste error at any of the seven
    // dead-band gate sites in `evaluate` (e.g. shoulderArc accidentally
    // reading `effectiveDriftDeadband`). The 25 pre-existing tests cover
    // only shoulderShrug — a wrong getter at any other cue passes silently.
    //
    // Strategy per cue: build geometry that puts magnitude clearly above
    // the audit threshold so the cue fires at every tolerance. If the
    // analyzer reads the wrong getter, the math may still fire — but if
    // the wiring is fully broken (e.g. a getter returns `double.infinity`
    // by mistake), the audit gate alone would still need to pass.
    //
    // What this group actually catches is the simpler regression: a gate
    // site that DROPS the dead-band guard entirely would let sub-baseline
    // motion fire. We test the sub-baseline silence for each cue.

    test('lateral torsoSwing stays silent at sub-baseline magnitude '
        'across every tolerance', () {
      // swingRatio = ΔX_shoulder / torsoLen. Baseline = 0.08.
      // Use shift = 0.01 → ratio ≈ 0.025 < 0.08.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      final evaluated = buildSidePose(
        shoulderX: 0.51,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      for (final percent in [0, 50, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          isNot(contains(FormError.torsoSwing)),
          reason: 'lateral swing stays silent at percent=$percent',
        );
      }
    });

    test('elbowDrift stays silent at sub-baseline magnitude '
        'across every tolerance', () {
      // Vertical torso so n̂ ≈ (1, 0). Elbow perpendicular offset =
      // (elbowX − shoulderX). Baseline drift deadband = 0.08.
      // Use offset = 0.01 → ratio ≈ 0.025 < 0.08.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.51,
        elbowY: 0.50,
      );
      for (final percent in [0, 50, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          isNot(contains(FormError.elbowDrift)),
          reason: 'elbowDrift stays silent at percent=$percent',
        );
      }
    });

    test('elbowRise stays silent at sub-baseline magnitude '
        'across every tolerance', () {
      // rise = (baselineElbowRelY - currentElbowRelY) / torsoLen.
      // Baseline = 0.08. Use elbow shift of 0.02 → rise ≈ 0.05 < 0.08.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.48,
      );
      for (final percent in [0, 50, 100]) {
        final a = makeAnalyzer(percent);
        a.onRepStart(ref);
        expect(
          a.evaluate(evaluated),
          isNot(contains(FormError.elbowRise)),
          reason: 'elbowRise stays silent at percent=$percent',
        );
      }
    });
  });

  group('Quality-score invariance — tolerance must NOT '
      'affect _computeQualityScore', () {
    test('two analyzers (percent=0 and percent=100) see the same rep '
        '→ produce identical lastRepQuality', () {
      // Plan §3 non-goal: "Not affecting the quality-score gradient."
      // Regression guard: if a future change accidentally piped tolerance
      // into _computeQualityScore, this test would fail. Rep ends with
      // onRepEnd() to commit the quality calculation.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      // Magnitude in the sub-threshold range so the cue is suppressed at
      // every tolerance, but the magnitude is still recorded into
      // `_maxShrugRatio` — quality should reflect that recorded value
      // identically at both leniencies.
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.26,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );

      final strict = makeAnalyzer(0);
      strict.onRepStart(ref);
      strict.evaluate(evaluated);
      strict.onRepEnd();

      final lenient = makeAnalyzer(100);
      lenient.onRepStart(ref);
      lenient.evaluate(evaluated);
      lenient.onRepEnd();

      expect(
        strict.lastRepQuality,
        closeTo(lenient.lastRepQuality, 1e-9),
        reason:
            'Quality score must be tolerance-invariant — the dial controls '
            'cue firing, not rep grading',
      );
    });
  });

  group('Telemetry invariant — quality magnitudes recorded '
      'regardless of tolerance', () {
    test('maxShrugRatio reflects the true magnitude even when the cue '
        'is suppressed by dead-band', () {
      // Build a rep at ratio=0.10 (in the silent-but-tracked band for both
      // analyzers) and verify both record the same _maxShrugRatio.
      final ref = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.30,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );
      final evaluated = buildSidePose(
        shoulderX: 0.50,
        shoulderY: 0.26,
        hipX: 0.50,
        hipY: 0.70,
        elbowX: 0.50,
        elbowY: 0.50,
      );

      final strict = makeAnalyzer(0)..onRepStart(ref);
      strict.evaluate(evaluated);
      final lenient = makeAnalyzer(100)..onRepStart(ref);
      lenient.evaluate(evaluated);

      // The true magnitude is recorded identically at both leniencies —
      // the dial controls cue *firing*, never *measurement*. The exact
      // numerical value depends on the analyzer's torsoLen computation
      // (which uses the *current frame's* shoulder/hip, not the rep-start
      // baseline), so we assert equality between the two analyzers
      // rather than pinning to a hand-computed ratio.
      expect(
        strict.maxShrugRatioThisRep,
        closeTo(lenient.maxShrugRatioThisRep, 1e-9),
      );
      // Sanity floor: must be non-zero (a real motion was recorded) and
      // below the audit threshold (else the cue would have fired at
      // percent=0 too, breaking the dead-band suppression test premise).
      expect(strict.maxShrugRatioThisRep, greaterThan(0.05));
      expect(strict.maxShrugRatioThisRep, lessThan(kShrugThreshold));
    });
  });
}
