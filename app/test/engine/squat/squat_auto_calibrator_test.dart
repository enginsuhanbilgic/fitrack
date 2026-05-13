import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/squat/squat_auto_calibrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SquatAutoCalibrator — emission gate', () {
    test('repCount < 2 → currentThresholds is null', () {
      final c = SquatAutoCalibrator();
      expect(c.currentThresholds, isNull);
      expect(c.repCount, 0);

      c.recordRepExtremes(85, 170);
      expect(c.repCount, 1);
      expect(c.currentThresholds, isNull);
    });

    test(
      '2 reps with ROM < kSquatMinViableRomDegrees → currentThresholds is null',
      () {
        final c = SquatAutoCalibrator();
        // ROM excursion = 170 - 140 = 30° → below 40° viable floor.
        c.recordRepExtremes(140, 170);
        c.recordRepExtremes(140, 170);
        expect(c.repCount, 2);
        expect(c.currentThresholds, isNull);
      },
    );

    test('2 reps with viable ROM → emits non-null thresholds with margins', () {
      final c = SquatAutoCalibrator();
      // ROM = 175 - 85 = 90° (well above 40° viable floor).
      c.recordRepExtremes(85, 175);
      c.recordRepExtremes(85, 175);
      expect(c.repCount, 2);

      final t = c.currentThresholds!;
      // start = max - startMargin (10) = 165.
      // bottom = min + bottomMargin (5) = 90.
      // end = max - endMargin (5) = 170.
      expect(t.startAngle, closeTo(175 - kSquatProfileStartMargin, 1e-9));
      expect(t.bottomAngle, closeTo(85 + kSquatProfileBottomMargin, 1e-9));
      expect(t.endAngle, closeTo(175 - kSquatProfileEndMargin, 1e-9));
    });
  });

  group('SquatAutoCalibrator — running averages', () {
    test('running avg shifts toward subsequent samples', () {
      final c = SquatAutoCalibrator();
      // Rep 1 seeds the averages.
      c.recordRepExtremes(80, 170);
      // Rep 2 pulls each toward the new sample: avg_min = (80+90)/2 = 85.
      c.recordRepExtremes(90, 180);
      final t = c.currentThresholds!;
      // start = 175 - 10 = 165.
      // bottom = 85 + 5 = 90.
      // end = 175 - 5 = 170.
      expect(t.startAngle, closeTo(165, 1e-9));
      expect(t.bottomAngle, closeTo(90, 1e-9));
      expect(t.endAngle, closeTo(170, 1e-9));
    });
  });

  group('SquatAutoCalibrator — MAD outlier rejection per-dimension', () {
    test('a min-side outlier does not pollute the running average', () {
      final c = SquatAutoCalibrator();
      // Seed a stable window — need ≥4 samples for MAD to engage.
      // Each rep's max=170 is constant → MAD returns false (mad==0 guard),
      // so max-side always accepted.
      c.recordRepExtremes(80, 170);
      c.recordRepExtremes(81, 170);
      c.recordRepExtremes(82, 170);
      c.recordRepExtremes(83, 170);
      c.recordRepExtremes(84, 170);
      // Now window is [80,81,82,83,84] — wildly outlier on min=30°.
      final avgBefore = c.currentThresholds!.bottomAngle;
      c.recordRepExtremes(30, 170);
      final avgAfter = c.currentThresholds!.bottomAngle;
      // The min-side outlier was rejected, so the bottomAngle (derived
      // from _minAvg) should be unchanged.
      expect(avgAfter, closeTo(avgBefore, 1e-9));
    });

    test('outlier on one dimension does not block the other', () {
      final c = SquatAutoCalibrator();
      // Seed with natural variance so MAD has a real spread to test
      // against. A constant-window has mad=0 → the constant-window guard
      // would mark NO sample as outlier, defeating the assertion.
      c.recordRepExtremes(80, 170);
      c.recordRepExtremes(81, 171);
      c.recordRepExtremes(79, 169);
      c.recordRepExtremes(82, 170);
      c.recordRepExtremes(80, 171);

      final endBefore = c.currentThresholds!.endAngle;
      final bottomBefore = c.currentThresholds!.bottomAngle;

      // min=30° is far outside [79, 82] — MAD will reject. max=170 is
      // squarely in the [169, 171] distribution → accepted.
      c.recordRepExtremes(30, 170);

      final endAfter = c.currentThresholds!.endAngle;
      final bottomAfter = c.currentThresholds!.bottomAngle;

      // Min side rejected → _minAvg unchanged → bottomAngle unchanged.
      expect(bottomAfter, closeTo(bottomBefore, 1e-9));
      // Max side accepted → running avg shifts toward 170 (already near
      // 170, so the shift is small but possibly non-zero).
      expect(endAfter, closeTo(endBefore, 0.2));
    });
  });

  group('SquatAutoCalibrator — reset', () {
    test('reset clears all state', () {
      final c = SquatAutoCalibrator();
      c.recordRepExtremes(85, 170);
      c.recordRepExtremes(85, 175);
      expect(c.repCount, 2);
      expect(c.currentThresholds, isNotNull);

      c.reset();
      expect(c.repCount, 0);
      expect(c.currentThresholds, isNull);

      // After reset, a fresh single rep brings repCount to 1 (not 3).
      c.recordRepExtremes(85, 170);
      expect(c.repCount, 1);
    });
  });
}
