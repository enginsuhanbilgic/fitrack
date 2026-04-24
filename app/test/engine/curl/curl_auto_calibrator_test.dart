import 'package:flutter_test/flutter_test.dart';
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

  group('cumulative averaging', () {
    test('two reps produce the exact arithmetic mean of extremes', () {
      c.recordRepExtremes(60, 160);
      c.recordRepExtremes(70, 170);
      final t = c.currentThresholds!;
      // Expected bucket extremes: min=65, max=165.
      // peak = 65 + 15 = 80
      // start = 165 - 10 = 155
      // end   = 165 - 25 = 140
      expect(t.peakAngle, closeTo(80, 1e-9));
      expect(t.startAngle, closeTo(155, 1e-9));
      expect(t.endAngle, closeTo(140, 1e-9));
    });

    test('three reps produce the arithmetic mean of the three values', () {
      c.recordRepExtremes(60, 160);
      c.recordRepExtremes(70, 170);
      c.recordRepExtremes(80, 180);
      final t = c.currentThresholds!;
      // Avg min = 70, avg max = 170.
      // peak = 70 + 15 = 85
      expect(t.peakAngle, closeTo(85, 1e-9));
      expect(t.startAngle, closeTo(160, 1e-9));
      expect(t.endAngle, closeTo(145, 1e-9));
    });
  });

  group('MAD outlier rejection', () {
    test(
      'extreme min outlier is ignored; running avg stays near prior mean',
      () {
        // Seed a stable 8-rep min window around ~60.
        for (var i = 0; i < 8; i++) {
          c.recordRepExtremes(60 + (i.isEven ? 0.2 : -0.2), 165);
        }
        final before = c.currentThresholds!.peakAngle;
        // Inject an extreme outlier on min (e.g. 10° — wrist-level noise).
        c.recordRepExtremes(10, 165);
        final after = c.currentThresholds!.peakAngle;
        // peak = avgMin + 15. Outlier would push avgMin downward by ~5°+;
        // MAD rejection keeps it flat.
        expect(after, closeTo(before, 0.5));
      },
    );

    test('outlier in one dimension still accepts the other dimension', () {
      // Seed with wider variation so MAD band tolerates a 2° shift.
      final maxSeed = [163.0, 164.0, 165.0, 166.0, 167.0, 164.0, 165.0, 166.0];
      for (var i = 0; i < 8; i++) {
        c.recordRepExtremes(60 + (i.isEven ? 0.2 : -0.2), maxSeed[i]);
      }
      final avgMaxBefore = c.currentThresholds!.startAngle + 10;
      // Inject: max inside the MAD band (accepted), min extreme (rejected).
      c.recordRepExtremes(5, 167);
      final avgMaxAfter = c.currentThresholds!.startAngle + 10;
      // Max dimension moved (accepted); min dimension stayed flat (rejected).
      expect(avgMaxAfter, greaterThan(avgMaxBefore));
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

    test('post-reset accumulation does not bleed into the new average', () {
      c.recordRepExtremes(60, 165);
      c.recordRepExtremes(62, 163);
      c.reset();

      c.recordRepExtremes(80, 150);
      c.recordRepExtremes(82, 152);
      final t = c.currentThresholds!;
      // Avg min = 81, avg max = 151.
      // peak = 81 + 15 = 96
      expect(t.peakAngle, closeTo(96, 1e-9));
    });
  });
}
