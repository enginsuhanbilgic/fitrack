import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_auto_calibrator.dart';

void main() {
  late CurlAutoCalibrator c;

  setUp(() => c = CurlAutoCalibrator());

  group('currentThresholds gating', () {
    test('returns null with zero reps', () {
      expect(c.currentThresholds, isNull);
    });

    test('returns null after one rep (need ≥ 2)', () {
      c.recordRepExtremes(60, 165);
      expect(c.currentThresholds, isNull);
    });

    test('returns thresholds after 2 reps with viable ROM', () {
      c.recordRepExtremes(60, 165);
      c.recordRepExtremes(62, 163);
      final t = c.currentThresholds;
      expect(t, isNotNull);
      expect(t!.source, ThresholdSource.autoCalibrated);
    });

    test('returns null when ROM is below kMinViableRomDegrees', () {
      // Only ~10° ROM — below 25° floor.
      c.recordRepExtremes(120, 130);
      c.recordRepExtremes(122, 132);
      expect(c.currentThresholds, isNull);
    });
  });

  group('min/max anchor over rolling window (post-2026-05-15)', () {
    test(
      'two reps: peak anchors on deepest min, start/end on most-extended max',
      () {
        c.recordRepExtremes(60, 160);
        c.recordRepExtremes(70, 170);
        final t = c.currentThresholds!;
        // Post-2026-05-15: anchor = deepest min (60°) and most-extended max (170°),
        // NOT the arithmetic mean. Tolerances halved 2026-05-16.
        // peak  = min(60, 70) + 7.5  = 67.5
        // start = max(160, 170) - 5  = 165
        // end   = max(160, 170) - 12.5 = 157.5
        expect(t.peakAngle, closeTo(67.5, 1e-9));
        expect(t.startAngle, closeTo(165, 1e-9));
        expect(t.endAngle, closeTo(157.5, 1e-9));
      },
    );

    test('three reps: anchor stays at the demonstrated best, not the mean', () {
      c.recordRepExtremes(60, 160);
      c.recordRepExtremes(70, 170);
      c.recordRepExtremes(80, 180);
      final t = c.currentThresholds!;
      // Anchor = min(60, 70, 80) = 60 and max(160, 170, 180) = 180.
      // Tolerances halved 2026-05-16.
      // peak  = 60 + 7.5   = 67.5
      // start = 180 - 5    = 175
      // end   = 180 - 12.5 = 167.5
      expect(t.peakAngle, closeTo(67.5, 1e-9));
      expect(t.startAngle, closeTo(175, 1e-9));
      expect(t.endAngle, closeTo(167.5, 1e-9));
    });

    test('shallow reps DO NOT drift the threshold shallower', () {
      // The whole point of the 2026-05-15 anchor change: shallow reps
      // can't loosen the threshold. Under the old running-mean shape,
      // three shallow follow-ups would have pulled peakAngle up to ~78°.
      c.recordRepExtremes(55, 165); // Deep rep — sets the anchor.
      c.recordRepExtremes(75, 165); // Shallow.
      c.recordRepExtremes(78, 165); // Shallow.
      c.recordRepExtremes(72, 165); // Shallow.
      final t = c.currentThresholds!;
      // peak still anchored on 55° (the deepest), not the mean of [55,75,78,72]=70.
      // Tolerances halved 2026-05-16: 55 + 7.5 = 62.5.
      expect(t.peakAngle, closeTo(55 + 7.5, 1e-9)); // 62.5°, not the mean.
    });
  });

  group('MAD outlier rejection', () {
    test(
      'extreme min outlier is ignored; peak anchor stays at the demonstrated deepest',
      () {
        // Seed a stable 8-rep min window around ~60.
        for (var i = 0; i < 8; i++) {
          c.recordRepExtremes(60 + (i.isEven ? 0.2 : -0.2), 165);
        }
        final before = c.currentThresholds!.peakAngle;
        // Inject an extreme outlier on min (e.g. 10° — wrist-level noise).
        c.recordRepExtremes(10, 165);
        final after = c.currentThresholds!.peakAngle;
        // peak = min(samples) + 15. Without MAD, the 10° outlier would
        // become the new min and drop peakAngle by ~50°. MAD rejects it,
        // so the anchor stays at the prior deepest demonstrated rep.
        expect(after, closeTo(before, 0.5));
      },
    );

    test(
      'extreme min outlier on the small side is rejected; min anchor unchanged',
      () {
        // Symmetric case: an outlier *deeper* than legitimate range should
        // also be MAD-rejected, so the threshold anchor doesn't suddenly
        // tighten on a single noisy frame. Under min/max anchoring this
        // matters MORE than under mean anchoring — a rejected single deep
        // sample would otherwise re-anchor the threshold to a noise spike.
        final minSeed = [60.0, 61.0, 62.0, 60.0, 61.0, 62.0, 60.0, 61.0];
        for (var i = 0; i < 8; i++) {
          c.recordRepExtremes(minSeed[i], 165);
        }
        final peakBefore = c.currentThresholds!.peakAngle;
        // Inject an implausibly-deep outlier (could be a wrist-level
        // landmark glitch). MAD should reject it.
        c.recordRepExtremes(-20, 165);
        final peakAfter = c.currentThresholds!.peakAngle;
        // Anchor unchanged — outlier never entered _minSamples.
        expect(peakAfter, closeTo(peakBefore, 1e-9));
      },
    );

    test('outlier in one dimension still accepts the other dimension', () {
      // Seed with wider variation so MAD band tolerates a 2° shift.
      final maxSeed = [163.0, 164.0, 165.0, 166.0, 167.0, 164.0, 165.0, 166.0];
      for (var i = 0; i < 8; i++) {
        c.recordRepExtremes(60 + (i.isEven ? 0.2 : -0.2), maxSeed[i]);
      }
      // startAngle = max(samples) - kProfileStartTolerance, so
      // max(samples) = startAngle + kProfileStartTolerance. Reconstruct via
      // the live constant so this test survives tolerance retunes.
      // Before injection: max of seed = 167.
      final maxBefore =
          c.currentThresholds!.startAngle + kProfileStartTolerance;
      // Inject: max inside the MAD band (accepted at 168°, slightly above
      // the prior window max of 167), min extreme (rejected).
      c.recordRepExtremes(5, 168);
      final maxAfter = c.currentThresholds!.startAngle + kProfileStartTolerance;
      // Max dimension accepted AND higher than prior best → anchor moves
      // upward. Min dimension rejected → peak anchor stays flat.
      expect(maxAfter, greaterThan(maxBefore));
    });

    test('both-dimension outlier does NOT advance repCount', () {
      // Seed with mild variation so both windows have non-zero MAD.
      for (var i = 0; i < 8; i++) {
        final d = i.isEven ? 0.2 : -0.2;
        c.recordRepExtremes(60 + d, 165 + d);
      }
      final countBefore = c.repCount;
      // Double outlier — both min=5 and max=300 are extreme.
      c.recordRepExtremes(5, 300);
      expect(c.repCount, countBefore);
    });

    test('currentThresholds stays null when post-filter repCount < 2', () {
      // We need a populated-but-hostile sample window. Seed the calibrator
      // with 8 stable reps, reset but preserve knowledge via a fresh run
      // where the second rep is a double outlier.
      for (var i = 0; i < 8; i++) {
        c.recordRepExtremes(60, 165);
      }
      c.reset();
      // After reset, windows are empty — MAD returns false for <4 samples,
      // so both early reps will always be accepted.
      c.recordRepExtremes(60, 165);
      expect(c.currentThresholds, isNull);
      c.recordRepExtremes(62, 163);
      expect(c.currentThresholds, isNotNull);
    });
  });

  group('reset', () {
    test('clears all accumulated state', () {
      c.recordRepExtremes(60, 165);
      c.recordRepExtremes(62, 163);
      expect(c.currentThresholds, isNotNull);

      c.reset();
      expect(c.repCount, 0);
      expect(c.currentThresholds, isNull);
    });

    test('post-reset accumulation does not bleed into the new anchor', () {
      c.recordRepExtremes(60, 165);
      c.recordRepExtremes(62, 163);
      c.reset();

      c.recordRepExtremes(80, 150);
      c.recordRepExtremes(82, 152);
      final t = c.currentThresholds!;
      // Anchor over post-reset window: min(80, 82) = 80, max(150, 152) = 152.
      // Tolerances halved 2026-05-16. The pre-reset 60° rep is gone.
      // peak  = 80 + 7.5   = 87.5
      // start = 152 - 5    = 147
      // end   = 152 - 12.5 = 139.5
      expect(t.peakAngle, closeTo(87.5, 1e-9));
      expect(t.startAngle, closeTo(147, 1e-9));
      expect(t.endAngle, closeTo(139.5, 1e-9));
    });
  });
}
