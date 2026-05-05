/// Characterization tests for CurlFormAnalyzer.
///
/// These tests lock the CURRENT behavior before feature phases F4–F7 land.
/// Some test names (e.g. `shortRom`) mirror the current enum values; later
/// phases rename them — tests will be updated then. Asymmetry was split in
/// Phase 7 (F6) into `asymmetryLeftLag` / `asymmetryRightLag`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/engine/curl/curl_form_analyzer.dart';
import 'package:fitrack/engine/curl/dtw_scorer.dart';

import '_pose_fixtures.dart';

void main() {
  late CurlFormAnalyzer a;

  setUp(() => a = CurlFormAnalyzer());

  // Default pose has torso length = |0.30 − 0.70| = 0.40.
  //   Swing threshold: 0.25 → needs horizontal shoulder shift > 0.10.
  //   Drift threshold: 0.20 → needs horizontal elbow shift > 0.08.

  group('torso swing', () {
    test('emits torsoSwing when shoulder shift ratio exceeds threshold', () {
      final ref = buildPose();
      a.onRepStart(ref);
      final swung = shiftLandmarks(ref, {
        11,
        12,
      }, 0.15); // 0.15 / 0.40 = 0.375 > 0.25
      expect(a.evaluate(swung), contains(FormError.torsoSwing));
    });

    test('does NOT emit below threshold', () {
      final ref = buildPose();
      a.onRepStart(ref);
      final tiny = shiftLandmarks(ref, {
        11,
        12,
      }, 0.05); // 0.05 / 0.40 = 0.125 < 0.25
      expect(a.evaluate(tiny), isNot(contains(FormError.torsoSwing)));
    });

    test('tracks maxSwingRatio across the rep for quality deduction', () {
      final ref = buildPose();
      a.onRepStart(ref);
      a.evaluate(shiftLandmarks(ref, {11, 12}, 0.15)); // ratio ≈ 0.375
      a.evaluate(ref); // no shift — should NOT erase the prior max
      a.onRepEnd();
      // Peak ratio 0.375 = 1.5× threshold; severity = (0.375−0.25)/0.25 = 0.5.
      // Deduction = 0.5 * kQualitySwingMaxDeduction (0.25) = 0.125.
      expect(a.lastRepQuality, closeTo(1.0 - 0.125, 1e-9));
    });
  });

  group('elbow drift', () {
    test('emits elbowDrift when ratio exceeds threshold', () {
      final ref = buildPose();
      a.onRepStart(ref);
      final drifted = shiftLandmarks(ref, {
        13,
        14,
      }, 0.12); // 0.12 / 0.40 = 0.30 > 0.20
      expect(a.evaluate(drifted), contains(FormError.elbowDrift));
    });

    test('normalizes by torso length — same pixel shift, different torsos', () {
      // Short torso: hips moved up so |shoulder.y − hip.y| = 0.20.
      final refShort = buildPose(leftHipY: 0.50, rightHipY: 0.50);
      a.onRepStart(refShort);
      final driftShort = shiftLandmarks(refShort, {
        13,
        14,
      }, 0.05); // 0.05 / 0.20 = 0.25 > 0.20
      expect(a.evaluate(driftShort), contains(FormError.elbowDrift));

      // Long torso (0.40) — same pixel shift is only 0.125 ratio → no emission.
      final b = CurlFormAnalyzer();
      final refLong = buildPose();
      b.onRepStart(refLong);
      final driftLong = shiftLandmarks(refLong, {13, 14}, 0.05);
      expect(b.evaluate(driftLong), isNot(contains(FormError.elbowDrift)));
    });
  });

  group('short ROM', () {
    // Canonical thresholds for the group: start=160°, peak=70°.
    // `kShortRomTolerance = 5.0°` so a rep counts as:
    //   • shortRomPeak  when minAngleReached > 75°  (classic abandoned rep)
    //   • shortRomStart when maxAngleAtStart < 155° AND peak ok
    final canonical = const RomThresholds(
      startAngle: 160,
      peakAngle: 70,
      peakExitAngle: 85,
      endAngle: 140,
      source: ThresholdSource.global,
    );

    test('emits shortRomPeak for classic abandoned rep', () {
      a.setActiveThresholds(canonical);
      a.onRepStart(buildPose());
      a.onAbortedRep(maxAngleAtStart: 160, minAngleReached: 90);
      expect(a.consumeCompletionErrors(), contains(FormError.shortRomPeak));
    });

    test('second drain does NOT re-emit shortRomPeak', () {
      a.setActiveThresholds(canonical);
      a.onRepStart(buildPose());
      a.onAbortedRep(maxAngleAtStart: 160, minAngleReached: 90);
      a.consumeCompletionErrors();
      expect(
        a.consumeCompletionErrors(),
        isNot(contains(FormError.shortRomPeak)),
      );
    });

    test('emits shortRomStart when arm did not start fully extended', () {
      a.setActiveThresholds(canonical);
      a.onRepStart(buildPose());
      // Peak reached (min 65 ≤ 75 tolerance band), but start only 148° < 155°.
      a.onAbortedRep(maxAngleAtStart: 148, minAngleReached: 65);
      expect(a.consumeCompletionErrors(), contains(FormError.shortRomStart));
    });

    test('peak shortfall takes precedence over start shortfall', () {
      a.setActiveThresholds(canonical);
      a.onRepStart(buildPose());
      // Both ends off: start 148° AND peak 90°. Peak wins.
      a.onAbortedRep(maxAngleAtStart: 148, minAngleReached: 90);
      final errs = a.consumeCompletionErrors();
      expect(errs, contains(FormError.shortRomPeak));
      expect(errs, isNot(contains(FormError.shortRomStart)));
    });

    test('no emission when both ends are within tolerance', () {
      a.setActiveThresholds(canonical);
      a.onRepStart(buildPose());
      // start 157° (only 3° short — within 5° tol), peak 72° (within 5° tol).
      a.onAbortedRep(maxAngleAtStart: 157, minAngleReached: 72);
      final errs = a.consumeCompletionErrors();
      expect(errs, isNot(contains(FormError.shortRomStart)));
      expect(errs, isNot(contains(FormError.shortRomPeak)));
    });

    test('setActiveThresholds: latest call wins for classification', () {
      // First install permissive thresholds, then tighten them — the tightened
      // thresholds must govern the next classification.
      a.setActiveThresholds(canonical);
      final tightened = const RomThresholds(
        startAngle: 170, // now demands near-full extension
        peakAngle: 50, // now demands deeper flexion
        peakExitAngle: 65,
        endAngle: 150,
        source: ThresholdSource.calibrated,
      );
      a.setActiveThresholds(tightened);
      a.onRepStart(buildPose());
      // Same extremes that were fine under canonical are now peak-short.
      a.onAbortedRep(maxAngleAtStart: 170, minAngleReached: 70);
      expect(a.consumeCompletionErrors(), contains(FormError.shortRomPeak));
    });
  });

  group('eccentric tempo', () {
    test(
      'emits eccentricTooFast when last eccentric < kMinEccentricSec',
      () async {
        a.onRepStart(buildPose());
        a.onPeakReached();
        a.onEccentricStart();
        // Drain immediately — eccentric duration ~0 ms < 800 ms threshold.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        a.onRepEnd();
        expect(
          a.consumeCompletionErrors(),
          contains(FormError.eccentricTooFast),
        );
      },
    );

    test('eccentricTooFastCount increments per qualifying rep', () async {
      for (var i = 0; i < 3; i++) {
        a.onRepStart(buildPose());
        a.onPeakReached();
        a.onEccentricStart();
        await Future<void>.delayed(const Duration(milliseconds: 5));
        a.onRepEnd();
        a.consumeCompletionErrors();
      }
      expect(a.eccentricTooFastCount, 3);
    });
  });

  group('concentric tempo', () {
    test(
      'emits concentricTooFast when concentric < kMinConcentricSec',
      () async {
        a.onRepStart(buildPose());
        // ~0 ms concentric — under 300 ms threshold.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        a.onPeakReached();
        a.onEccentricStart();
        a.onRepEnd();
        expect(
          a.consumeCompletionErrors(),
          contains(FormError.concentricTooFast),
        );
      },
    );

    test('does NOT emit when concentric exceeds minimum', () async {
      a.onRepStart(buildPose());
      // Wait longer than 300 ms before peak.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      a.onPeakReached();
      a.onEccentricStart();
      a.onRepEnd();
      expect(
        a.consumeCompletionErrors(),
        isNot(contains(FormError.concentricTooFast)),
      );
    });

    test(
      'quality score deducts kQualityConcentricDeduction on fast lift',
      () async {
        a.onRepStart(buildPose());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        a.onPeakReached();
        // Skip onEccentricStart so eccentric deduction does NOT apply.
        a.onRepEnd();
        expect(
          a.lastRepQuality,
          closeTo(1.0 - kQualityConcentricDeduction, 1e-9),
        );
      },
    );

    test('concentricTooFastCount increments per qualifying rep', () async {
      for (var i = 0; i < 3; i++) {
        a.onRepStart(buildPose());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        a.onPeakReached();
        a.onEccentricStart();
        a.onRepEnd();
        a.consumeCompletionErrors();
      }
      expect(a.concentricTooFastCount, 3);
    });
  });

  group('bilateral asymmetry (front view only)', () {
    setUp(() => a.setView(CurlCameraView.front));

    // A lagging arm has a HIGHER min-angle (it didn't flex as deeply).
    //   left=80, right=60  → left is lagging → asymmetryLeftLag
    //   left=60, right=80  → right is lagging → asymmetryRightLag

    test('no emission below kAsymmetryConsecutiveReps streak', () {
      for (var i = 0; i < kAsymmetryConsecutiveReps - 1; i++) {
        a.onRepStart(buildPose());
        a.recordBilateralAngles(60.0, 80.0); // delta 20 > 15, right lagging
        a.onRepEnd();
        final errs = a.consumeCompletionErrors();
        expect(errs, isNot(contains(FormError.asymmetryLeftLag)));
        expect(errs, isNot(contains(FormError.asymmetryRightLag)));
      }
    });

    test('emits asymmetryRightLag when right min-angle is higher', () {
      List<FormError>? last;
      for (var i = 0; i < kAsymmetryConsecutiveReps; i++) {
        a.onRepStart(buildPose());
        a.recordBilateralAngles(60.0, 80.0); // right higher → right lagging
        a.onRepEnd();
        last = a.consumeCompletionErrors();
      }
      expect(last, contains(FormError.asymmetryRightLag));
      expect(last, isNot(contains(FormError.asymmetryLeftLag)));
    });

    test('emits asymmetryLeftLag when left min-angle is higher', () {
      List<FormError>? last;
      for (var i = 0; i < kAsymmetryConsecutiveReps; i++) {
        a.onRepStart(buildPose());
        a.recordBilateralAngles(80.0, 60.0); // left higher → left lagging
        a.onRepEnd();
        last = a.consumeCompletionErrors();
      }
      expect(last, contains(FormError.asymmetryLeftLag));
      expect(last, isNot(contains(FormError.asymmetryRightLag)));
    });

    test('streak resets on a symmetric rep regardless of direction', () {
      // Two over-delta reps (right lagging) — not enough to fire at N=3.
      for (var i = 0; i < 2; i++) {
        a.onRepStart(buildPose());
        a.recordBilateralAngles(60.0, 80.0);
        a.onRepEnd();
        a.consumeCompletionErrors();
      }
      // One symmetric rep — resets the streak.
      a.onRepStart(buildPose());
      a.recordBilateralAngles(70.0, 72.0);
      a.onRepEnd();
      final errs = a.consumeCompletionErrors();
      expect(errs, isNot(contains(FormError.asymmetryLeftLag)));
      expect(errs, isNot(contains(FormError.asymmetryRightLag)));
    });

    test('recordBilateralAngles is a no-op in side views', () {
      final b = CurlFormAnalyzer()..setView(CurlCameraView.sideLeft);
      for (var i = 0; i < kAsymmetryConsecutiveReps + 1; i++) {
        b.onRepStart(buildPose());
        b.recordBilateralAngles(60.0, 80.0);
        b.onRepEnd();
        final errs = b.consumeCompletionErrors();
        expect(errs, isNot(contains(FormError.asymmetryLeftLag)));
        expect(errs, isNot(contains(FormError.asymmetryRightLag)));
      }
    });
  });

  group('fatigue', () {
    test(
      'emits fatigue once when lastAvg / firstAvg > kFatigueSlowdownRatio',
      () async {
        // Need at least kFatigueMinReps (6) reps. First 3 fast, last 3 slow.
        for (var i = 0; i < kFatigueMinReps; i++) {
          a.onRepStart(buildPose());
          // Simulate concentric duration by sleeping between onRepStart and onPeakReached.
          final ms = i < 3 ? 20 : 60; // ratio 3.0 > 1.4
          await Future<void>.delayed(Duration(milliseconds: ms));
          a.onPeakReached();
          a.onEccentricStart();
          a.onRepEnd();
        }
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
        expect(a.fatigueDetected, isTrue);
      },
    );

    test('_fatigueFired prevents re-emission', () async {
      for (var i = 0; i < kFatigueMinReps; i++) {
        a.onRepStart(buildPose());
        final ms = i < 3 ? 20 : 60;
        await Future<void>.delayed(Duration(milliseconds: ms));
        a.onPeakReached();
        a.onEccentricStart();
        a.onRepEnd();
      }
      a.consumeCompletionErrors(); // first drain emits fatigue
      // Next rep: drain again — should NOT re-emit.
      a.onRepStart(buildPose());
      a.onPeakReached();
      a.onEccentricStart();
      a.onRepEnd();
      expect(a.consumeCompletionErrors(), isNot(contains(FormError.fatigue)));
    });
  });

  group('quality score', () {
    test('clean rep scores 1.0', () async {
      final b = CurlFormAnalyzer();
      b.onRepStart(buildPose());
      // Wait past kMinConcentricSec (0.3 s) so concentric is in-spec.
      await Future<void>.delayed(const Duration(milliseconds: 350));
      b.onPeakReached();
      // Skip onEccentricStart — _lastEccentricDuration stays null, no eccentric ding.
      b.onRepEnd();
      expect(b.lastRepQuality, closeTo(1.0, 1e-9));
    });

    test('stacked deductions clamp to 0.0 lower bound', () async {
      final ref = buildPose();
      a.onRepStart(ref);
      // Maximum swing + drift severity.
      a.evaluate(shiftLandmarks(ref, {11, 12, 13, 14}, 0.40));
      a.onAbortedRep(maxAngleAtStart: 160, minAngleReached: 100);
      a.onEccentricStart();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      a.onRepEnd();
      expect(a.lastRepQuality, greaterThanOrEqualTo(0.0));
      expect(a.lastRepQuality, lessThanOrEqualTo(1.0));
    });

    test('proportional swing deduction between threshold and 2× threshold', () {
      final ref = buildPose();
      a.onRepStart(ref);
      // Ratio = 0.375 → severity 0.5 → deduction 0.125.
      a.evaluate(shiftLandmarks(ref, {11, 12}, 0.15));
      a.onRepEnd();
      expect(a.lastRepQuality, closeTo(0.875, 1e-9));
    });

    test('averageQuality averages completed reps', () async {
      // Rep 1: clean — concentric > kMinConcentricSec, no eccentric tracked.
      a.onRepStart(buildPose());
      await Future<void>.delayed(const Duration(milliseconds: 350));
      a.onPeakReached();
      a.onRepEnd();
      // Rep 2: short ROM only (−0.30 deduction).
      // No onPeakReached so concentric duration stays null → no tempo deduction.
      a.onRepStart(buildPose());
      a.onAbortedRep(maxAngleAtStart: 160, minAngleReached: 100);
      a.onRepEnd();
      expect(a.averageQuality, closeTo((1.0 + 0.70) / 2.0, 1e-9));
    });
  });

  group('tempo consistency (concentric variance)', () {
    /// Helper: drive one rep whose concentric phase lasts `concentricMs`.
    /// onEccentricStart is intentionally skipped so the eccentric deduction
    /// and `eccentricTooFast` error do not contaminate the assertions here.
    Future<void> drive(int concentricMs) async {
      a.onRepStart(buildPose());
      await Future<void>.delayed(Duration(milliseconds: concentricMs));
      a.onPeakReached();
      a.onRepEnd();
    }

    test('no emission with fewer than kTempoConsistencyWindow reps', () async {
      await drive(400);
      await drive(600);
      expect(
        a.consumeCompletionErrors(),
        isNot(contains(FormError.tempoInconsistent)),
      );
    });

    test(
      'emits when variance ratio exceeds kTempoInconsistencyRatio',
      () async {
        // 3 reps with spread/mean ≈ 0.86 — well above 0.30 threshold.
        await drive(400);
        a.consumeCompletionErrors();
        await drive(400);
        a.consumeCompletionErrors();
        await drive(1000);
        expect(
          a.consumeCompletionErrors(),
          contains(FormError.tempoInconsistent),
        );
        expect(a.tempoInconsistentCount, 1);
      },
    );

    test('does NOT emit when window is tight enough', () async {
      // Durations vary by < 30% of mean (≈5% here).
      await drive(500);
      a.consumeCompletionErrors();
      await drive(520);
      a.consumeCompletionErrors();
      await drive(490);
      expect(
        a.consumeCompletionErrors(),
        isNot(contains(FormError.tempoInconsistent)),
      );
    });

    test('re-arm window suppresses re-emission, then re-fires', () async {
      // Trigger first emission.
      await drive(400);
      a.consumeCompletionErrors();
      await drive(400);
      a.consumeCompletionErrors();
      await drive(1000);
      expect(
        a.consumeCompletionErrors(),
        contains(FormError.tempoInconsistent),
      );
      expect(a.tempoInconsistentCount, 1);

      // Next kTempoConsistencyReArmReps reps must NOT re-emit even though
      // the variance stays high — tempo drift just fired, suppression active.
      for (var i = 0; i < kTempoConsistencyReArmReps; i++) {
        await drive(i.isEven ? 400 : 1000);
        expect(
          a.consumeCompletionErrors(),
          isNot(contains(FormError.tempoInconsistent)),
        );
      }
      expect(a.tempoInconsistentCount, 1); // still 1 during suppression

      // Re-arm counter is now 0. The next high-variance rep re-fires.
      await drive(400);
      expect(
        a.consumeCompletionErrors(),
        contains(FormError.tempoInconsistent),
      );
      expect(a.tempoInconsistentCount, 2);
    });

    test('quality score deducts kQualityTempoInconsistencyDeduction', () async {
      await drive(400);
      a.consumeCompletionErrors();
      await drive(400);
      a.consumeCompletionErrors();
      await drive(1000);
      final errs = a.consumeCompletionErrors();
      expect(errs, contains(FormError.tempoInconsistent));
      // Rep 3 had concentric 1000 ms (in-spec) and no eccentric tracked —
      // only the tempo deduction applies.
      expect(
        a.lastRepQuality,
        closeTo(1.0 - kQualityTempoInconsistencyDeduction, 1e-9),
      );
    });
  });

  group('DTW scoring', () {
    test('scoreRep returns null when enableDtwScoring is false (default)', () {
      final analyzer = CurlFormAnalyzer(
        referenceRepAngleSeries: List<double>.generate(64, (i) => i.toDouble()),
      );
      final result = analyzer.scoreRep(
        List<double>.generate(32, (i) => i.toDouble()),
      );
      expect(result, isNull);
    });

    test('scoreRep returns null when no reference series provided', () {
      final analyzer = CurlFormAnalyzer(enableDtwScoring: true);
      final result = analyzer.scoreRep(
        List<double>.generate(32, (i) => i.toDouble()),
      );
      expect(result, isNull);
    });

    test('scoreRep delegates to injected DtwScorer', () {
      const fixedScore = DtwScore(similarity: 0.88, rawDistance: 7.2);
      final analyzer = CurlFormAnalyzer(
        referenceRepAngleSeries: List<double>.generate(64, (i) => i.toDouble()),
        enableDtwScoring: true,
        dtwScorer: _FixedDtwScorer(fixedScore),
      );
      final result = analyzer.scoreRep(
        List<double>.generate(32, (i) => i.toDouble()),
      );
      expect(result, isNotNull);
      expect(result!.similarity, 0.88);
      expect(result.rawDistance, 7.2);
    });

    test(
      'existing tests unaffected — default analyzer has scoring disabled',
      () {
        // Default constructor: enableDtwScoring=false, no reference.
        // scoreRep always returns null; no other behavior changes.
        final analyzer = CurlFormAnalyzer();
        expect(analyzer.scoreRep([1.0, 2.0, 3.0]), isNull);
      },
    );
  });

  group('reset', () {
    test('clears all state including _fatigueFired', () async {
      // Trigger fatigue first.
      for (var i = 0; i < kFatigueMinReps; i++) {
        a.onRepStart(buildPose());
        final ms = i < 3 ? 20 : 60;
        await Future<void>.delayed(Duration(milliseconds: ms));
        a.onPeakReached();
        a.onEccentricStart();
        a.onRepEnd();
      }
      a.consumeCompletionErrors();
      expect(a.fatigueDetected, isTrue);

      a.reset();
      expect(a.fatigueDetected, isFalse);
      expect(a.eccentricTooFastCount, 0);
      expect(a.tempoInconsistentCount, 0);
      expect(a.repQualities, isEmpty);
      expect(a.averageQuality, 1.0); // default for empty list
      expect(a.lastRepQuality, 1.0);
    });
  });
}

/// Stub scorer that always returns a fixed [DtwScore] — isolates the analyzer's
/// wiring from the actual DTW math.
class _FixedDtwScorer extends DtwScorer {
  _FixedDtwScorer(this._fixed);
  final DtwScore _fixed;

  @override
  DtwScore score(List<double> candidate, List<double> reference) => _fixed;
}
