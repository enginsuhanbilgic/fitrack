/// Tests for the Form Tolerance Percent dial wired into `FormThresholds`.
///
/// Covers the linear-interpolation formula
/// `effective = baseline + (threshold − baseline) × percent / 100`
/// at boundary and midpoint values, the input-clamp contract on
/// `withTolerance`, and the defensive fallback when `baseline >= threshold`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/form_thresholds.dart';

void main() {
  group('FormThresholds.withTolerance boundary values', () {
    test('percent=0 → effective deadbands equal the baseline constants', () {
      final t = FormThresholds.withTolerance(0);
      expect(t.formTolerancePercent, 0);
      expect(t.effectiveSwingDeadband, kFormMinMovementSwingRatio);
      expect(t.effectiveLeanDeadband, kFormMinMovementLeanDeg);
      expect(t.effectiveBackLeanDeadband, kFormMinMovementLeanDeg);
      expect(t.effectiveShrugDeadband, kFormMinMovementShrugRatio);
      expect(t.effectiveDriftDeadband, kFormMinMovementDriftRatio);
    });

    test('percent=100 → effective deadbands equal the audit thresholds', () {
      final t = FormThresholds.withTolerance(100);
      expect(t.formTolerancePercent, 100);
      // `closeTo` with 1e-9 tolerance: the linear interpolation
      // `baseline + (threshold - baseline) * 100 / 100` can produce a
      // one-ULP rounding artifact even when algebraically equal to
      // `threshold`. Within IEEE-754 noise, not a real difference.
      expect(t.effectiveSwingDeadband, closeTo(kSwingThreshold, 1e-9));
      expect(t.effectiveLeanDeadband, closeTo(kTorsoLeanThresholdDeg, 1e-9));
      expect(t.effectiveBackLeanDeadband, closeTo(kBackLeanThresholdDeg, 1e-9));
      expect(t.effectiveShrugDeadband, closeTo(kShrugThreshold, 1e-9));
      expect(t.effectiveDriftDeadband, closeTo(kDriftThreshold, 1e-9));
    });
  });

  group('FormThresholds.withTolerance linear interpolation', () {
    test('percent=50 → effective deadbands sit at the midpoint per cue', () {
      final t = FormThresholds.withTolerance(50);

      double midpoint(double baseline, double threshold) =>
          baseline + (threshold - baseline) * 0.5;

      expect(
        t.effectiveSwingDeadband,
        closeTo(midpoint(kFormMinMovementSwingRatio, kSwingThreshold), 1e-9),
      );
      expect(
        t.effectiveLeanDeadband,
        closeTo(
          midpoint(kFormMinMovementLeanDeg, kTorsoLeanThresholdDeg),
          1e-9,
        ),
      );
      expect(
        t.effectiveBackLeanDeadband,
        closeTo(midpoint(kFormMinMovementLeanDeg, kBackLeanThresholdDeg), 1e-9),
      );
      expect(
        t.effectiveShrugDeadband,
        closeTo(midpoint(kFormMinMovementShrugRatio, kShrugThreshold), 1e-9),
      );
      expect(
        t.effectiveDriftDeadband,
        closeTo(midpoint(kFormMinMovementDriftRatio, kDriftThreshold), 1e-9),
      );
    });

    test('forward and back lean diverge at non-zero tolerance '
        '(different upper thresholds)', () {
      // Both legs share `kFormMinMovementLeanDeg` as baseline but interpolate
      // against different upper thresholds (12° forward vs 10° back). At
      // percent=100 their effective deadbands must differ.
      final t = FormThresholds.withTolerance(100);
      expect(t.effectiveLeanDeadband, kTorsoLeanThresholdDeg);
      expect(t.effectiveBackLeanDeadband, kBackLeanThresholdDeg);
      expect(
        t.effectiveLeanDeadband,
        isNot(equals(t.effectiveBackLeanDeadband)),
        reason: 'Forward lean threshold (12°) ≠ back lean threshold (10°)',
      );
    });
  });

  group('FormThresholds.withTolerance clamping', () {
    test('negative input is clamped to 0', () {
      final t = FormThresholds.withTolerance(-25);
      expect(t.formTolerancePercent, 0);
      expect(t.effectiveSwingDeadband, kFormMinMovementSwingRatio);
    });

    test('> 100 input is clamped to 100', () {
      final t = FormThresholds.withTolerance(150);
      expect(t.formTolerancePercent, 100);
      expect(t.effectiveSwingDeadband, kSwingThreshold);
    });

    test('FormThresholds direct ctor with out-of-range percent — getters '
        'still clamp at read time (defensive second line)', () {
      // Bypasses the withTolerance factory's clamp via the public const ctor.
      // The internal `_effectiveDeadband` helper applies its own clamp so a
      // misbehaving caller can't trip the formula into negative values.
      const t = FormThresholds(
        swingThreshold: kSwingThreshold,
        torsoLeanThresholdDeg: kTorsoLeanThresholdDeg,
        backLeanThresholdDeg: kBackLeanThresholdDeg,
        shrugThreshold: kShrugThreshold,
        driftThreshold: kDriftThreshold,
        formTolerancePercent: 250,
      );
      // Per the defensive clamp the effective value tops out at the
      // threshold, not above it.
      expect(t.effectiveSwingDeadband, kSwingThreshold);
    });
  });

  group('FormThresholds.medium default', () {
    test('default formTolerancePercent is the cold-start constant', () {
      const m = FormThresholds.medium;
      expect(m.formTolerancePercent, kDefaultFormTolerancePercent);
      // The default preserves the 2026-05-15 hard-coded behavior so
      // upgrading users see no behavior change at all.
      expect(m.effectiveSwingDeadband, kFormMinMovementSwingRatio);
      expect(m.effectiveLeanDeadband, kFormMinMovementLeanDeg);
      expect(m.effectiveBackLeanDeadband, kFormMinMovementLeanDeg);
      expect(m.effectiveShrugDeadband, kFormMinMovementShrugRatio);
      expect(m.effectiveDriftDeadband, kFormMinMovementDriftRatio);
    });
  });

  group('FormThresholds._effectiveDeadband degenerate guard', () {
    test('baseline >= threshold degenerates to the baseline '
        '(slider becomes a no-op for that cue)', () {
      // Forge a FormThresholds where the lean baseline (3°) exceeds the
      // lean threshold. The audit threshold is `torsoLeanThresholdDeg`,
      // so we drop the threshold below the baseline.
      const t = FormThresholds(
        swingThreshold: kSwingThreshold,
        torsoLeanThresholdDeg: 1.0, // < kFormMinMovementLeanDeg (3.0)
        backLeanThresholdDeg: kBackLeanThresholdDeg,
        shrugThreshold: kShrugThreshold,
        driftThreshold: kDriftThreshold,
        formTolerancePercent: 100,
      );
      // Even at the most lenient setting, the degenerate case returns the
      // baseline — the analyzer stays operational; only this one cue's
      // slider has no effect.
      expect(t.effectiveLeanDeadband, kFormMinMovementLeanDeg);
    });
  });
}
