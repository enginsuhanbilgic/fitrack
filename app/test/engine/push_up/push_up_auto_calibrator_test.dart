import 'package:fitrack/engine/push_up/push_up_auto_calibrator.dart';
import 'package:fitrack/engine/push_up/push_up_rom_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PushUpAutoCalibrator c;

  setUp(() => c = PushUpAutoCalibrator());

  group('PushUpAutoCalibrator — emission gate', () {
    test('returns null with zero reps', () {
      expect(c.currentThresholds, isNull);
      expect(c.repCount, 0);
    });

    test('returns null after one rep (need ≥ 2)', () {
      c.recordRepExtremes(170, 82);
      expect(c.repCount, 1);
      expect(c.currentThresholds, isNull);
    });

    test(
      '2 reps with ROM < kPushUpMinViableRomDegrees → currentThresholds is null',
      () {
        // ROM excursion = 130 - 100 = 30° → below the 40° viable floor.
        c.recordRepExtremes(130, 100);
        c.recordRepExtremes(130, 100);
        expect(c.repCount, 2);
        expect(c.currentThresholds, isNull);
      },
    );

    test('2 reps with viable ROM → emits non-null thresholds', () {
      c.recordRepExtremes(170, 82);
      c.recordRepExtremes(170, 82);
      expect(c.repCount, 2);
      expect(c.currentThresholds, isNotNull);
    });
  });

  group('PushUpAutoCalibrator — min/max anchor over rolling window', () {
    test(
      'anchor uses most-extended top and deepest bottom (NOT running mean)',
      () {
        c.recordRepExtremes(165, 85);
        c.recordRepExtremes(172, 80);
        final t = c.currentThresholds!;
        // Anchor on max(165, 172) = 172 and min(85, 80) = 80. Threshold
        // derivation must match `PushUpRomProfile.calibrated(top: 172,
        // bottom: 80).thresholds` exactly — that contract is the entire
        // reason auto-cal hands the anchor pair into the synthetic profile
        // factory instead of duplicating the percentage-of-ROM math.
        final expected = PushUpRomProfile.calibrated(
          topAngle: 172,
          bottomAngle: 80,
        ).thresholds;
        expect(t.startAngle, closeTo(expected.startAngle, 1e-9));
        expect(t.bottomAngle, closeTo(expected.bottomAngle, 1e-9));
        expect(
          t.shallowRepMaxAngle,
          closeTo(expected.shallowRepMaxAngle, 1e-9),
        );
        expect(t.endAngle, closeTo(expected.endAngle, 1e-9));
      },
    );

    test('shallow reps DO NOT drift the threshold shallower', () {
      // The whole point of the 2026-05-15 anchor change: shallow reps
      // can't loosen the threshold. Under a running-mean implementation,
      // three shallow follow-ups would have pulled bottomAngle's anchor
      // upward (less deep). Under min-anchor, the deepest rep wins.
      c.recordRepExtremes(170, 80); // Deep — sets the bottom anchor.
      c.recordRepExtremes(170, 95); // Shallow.
      c.recordRepExtremes(170, 100); // Shallower.
      c.recordRepExtremes(170, 92); // Shallow.
      final t = c.currentThresholds!;
      // bottomBest anchored on min(80, 95, 100, 92) = 80, not the mean
      // (~92). Threshold value matches the calibrated factory.
      final expected = PushUpRomProfile.calibrated(
        topAngle: 170,
        bottomAngle: 80,
      ).thresholds;
      expect(t.bottomAngle, closeTo(expected.bottomAngle, 1e-9));
    });

    test('regression: auto-cal thresholds match calibrated thresholds exactly '
        'for identical anchor pair', () {
      // Same inputs into both tiers must produce bit-for-bit identical
      // PushUpRomThresholds — the only difference between tier-1 and
      // tier-2 should be the *source* of the anchor, not the geometry.
      c.recordRepExtremes(168, 86);
      c.recordRepExtremes(168, 86);
      final tier2 = c.currentThresholds!;
      final tier1 = PushUpRomProfile.calibrated(
        topAngle: 168,
        bottomAngle: 86,
      ).thresholds;
      expect(tier2.startAngle, tier1.startAngle);
      expect(tier2.bottomAngle, tier1.bottomAngle);
      expect(tier2.shallowRepMaxAngle, tier1.shallowRepMaxAngle);
      expect(tier2.endAngle, tier1.endAngle);
    });
  });

  group('PushUpAutoCalibrator — MAD outlier rejection per-dimension', () {
    test('a bottom-side outlier is rejected and does not anchor', () {
      // Seed a stable 8-rep window — MAD needs ≥4 samples to engage.
      // Each rep's top=170 is constant → MAD returns false (constant-
      // window guard); top-side always accepted.
      for (var i = 0; i < 8; i++) {
        c.recordRepExtremes(170, 85 + (i.isEven ? 0.2 : -0.2));
      }
      final bottomBefore = c.currentThresholds!.bottomAngle;
      // Inject an outlier deep-bottom (e.g. 20° — landmark glitch). Under
      // min-anchor this matters MORE than under mean: if MAD failed to
      // reject, 20° would become the new min and drop the threshold by
      // ~60°. MAD rejection keeps the anchor at the prior deepest
      // legitimate rep (~84.8).
      c.recordRepExtremes(170, 20);
      final bottomAfter = c.currentThresholds!.bottomAngle;
      expect(bottomAfter, closeTo(bottomBefore, 1e-9));
    });

    test('outlier in one dimension does not block the other', () {
      // Seed with WIDE variance so MAD has real spread — important
      // because the post-injection test asserts the new top sample is
      // accepted by MAD AND sets a new max. With a tight seed the new
      // sample could itself be borderline-rejected, defeating the
      // assertion. Range here is [160, 172], spread ≈ 12° → MAD-rejection
      // boundary lands well above the injection value (175).
      final topSeed = [160.0, 163.0, 166.0, 169.0, 172.0, 165.0, 168.0, 170.0];
      for (var i = 0; i < 8; i++) {
        c.recordRepExtremes(topSeed[i], 85 + (i.isEven ? 0.2 : -0.2));
      }
      final topBefore = c.currentThresholds!;
      // Inject: top=175 — comfortably inside the MAD band (median≈167,
      // spread ≈ 4°, so MAD threshold ≈ 181) AND above the prior window
      // max of 172, so it sets a new max-anchor. Bottom=10° is extreme
      // far outside any plausible MAD band → rejected.
      c.recordRepExtremes(175, 10);
      final topAfter = c.currentThresholds!;
      // Top side accepted at a new max → startAngle anchor moves.
      // Bottom side rejected → bottomAngle anchor unchanged.
      expect(topAfter.startAngle, isNot(closeTo(topBefore.startAngle, 1e-9)));
      expect(topAfter.bottomAngle, closeTo(topBefore.bottomAngle, 1e-9));
    });

    test('both-dimension outlier does NOT advance repCount', () {
      // Seed with mild variation so both windows have non-zero MAD.
      for (var i = 0; i < 8; i++) {
        final d = i.isEven ? 0.2 : -0.2;
        c.recordRepExtremes(170 + d, 85 + d);
      }
      final countBefore = c.repCount;
      // Double outlier — both top=300 and bottom=5 are extreme.
      c.recordRepExtremes(300, 5);
      expect(c.repCount, countBefore);
    });
  });

  group('PushUpAutoCalibrator — reset', () {
    test('clears all accumulated state', () {
      c.recordRepExtremes(170, 85);
      c.recordRepExtremes(170, 82);
      expect(c.currentThresholds, isNotNull);

      c.reset();
      expect(c.repCount, 0);
      expect(c.currentThresholds, isNull);
    });

    test('post-reset accumulation does not bleed into the new anchor', () {
      c.recordRepExtremes(170, 80);
      c.recordRepExtremes(170, 82);
      c.reset();

      c.recordRepExtremes(165, 100);
      c.recordRepExtremes(165, 102);
      final t = c.currentThresholds!;
      // Post-reset anchor: top=max(165, 165)=165, bottom=min(100, 102)=100.
      // The pre-reset 80° bottom is gone.
      final expected = PushUpRomProfile.calibrated(
        topAngle: 165,
        bottomAngle: 100,
      ).thresholds;
      expect(t.startAngle, closeTo(expected.startAngle, 1e-9));
      expect(t.bottomAngle, closeTo(expected.bottomAngle, 1e-9));
    });
  });
}
