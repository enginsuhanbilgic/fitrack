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

  group(
    'SquatAutoCalibrator — min/max anchor over rolling window (post-2026-05-15)',
    () {
      test(
        'anchor uses deepest min and most-extended max, not running average',
        () {
          final c = SquatAutoCalibrator();
          c.recordRepExtremes(80, 170);
          c.recordRepExtremes(90, 180);
          final t = c.currentThresholds!;
          // Post-2026-05-15: anchor on min(80, 90) = 80 and max(170, 180) = 180,
          // NOT the running mean. Margins unchanged.
          // start  = 180 - kSquatProfileStartMargin
          // bottom = 80  + kSquatProfileBottomMargin
          // end    = 180 - kSquatProfileEndMargin
          expect(t.startAngle, closeTo(180 - kSquatProfileStartMargin, 1e-9));
          expect(t.bottomAngle, closeTo(80 + kSquatProfileBottomMargin, 1e-9));
          expect(t.endAngle, closeTo(180 - kSquatProfileEndMargin, 1e-9));
        },
      );

      test('shallow reps DO NOT drift the bottom threshold shallower', () {
        // The structural fix: under min-anchor a deep rep early in the set
        // locks the floor; later shallow reps cannot loosen it.
        final c = SquatAutoCalibrator();
        c.recordRepExtremes(55, 170); // Deep — sets the anchor.
        c.recordRepExtremes(80, 170); // Shallow.
        c.recordRepExtremes(85, 170); // Shallow.
        c.recordRepExtremes(82, 170); // Shallow.
        final t = c.currentThresholds!;
        // bottom anchored on 55° (deepest), not mean of [55, 80, 85, 82] = 75.5.
        expect(t.bottomAngle, closeTo(55 + kSquatProfileBottomMargin, 1e-9));
      });
    },
  );

  group('SquatAutoCalibrator — MAD outlier rejection per-dimension', () {
    test('a min-side outlier is rejected and does not anchor the threshold', () {
      final c = SquatAutoCalibrator();
      // Seed a stable window — need ≥4 samples for MAD to engage.
      // Each rep's max=170 is constant → MAD returns false (mad==0 guard),
      // so max-side always accepted.
      c.recordRepExtremes(80, 170);
      c.recordRepExtremes(81, 170);
      c.recordRepExtremes(82, 170);
      c.recordRepExtremes(83, 170);
      c.recordRepExtremes(84, 170);
      // Window is [80, 81, 82, 83, 84] — inject a wildly-outlier min=30°.
      // Under min/max anchoring this matters MORE than under mean anchoring:
      // if MAD failed to reject, 30° would become the new min and drop
      // bottomAngle by ~50°. MAD rejection keeps the anchor at min(80..84)=80.
      final bottomBefore = c.currentThresholds!.bottomAngle;
      c.recordRepExtremes(30, 170);
      final bottomAfter = c.currentThresholds!.bottomAngle;
      expect(bottomAfter, closeTo(bottomBefore, 1e-9));
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
      // squarely in the [169, 171] distribution → accepted (but already
      // matches the prior window max, so max(samples) doesn't move).
      c.recordRepExtremes(30, 170);

      final endAfter = c.currentThresholds!.endAngle;
      final bottomAfter = c.currentThresholds!.bottomAngle;

      // Min side rejected → bottomAngle anchor unchanged.
      expect(bottomAfter, closeTo(bottomBefore, 1e-9));
      // Max side accepted at 170 but the prior window max was already 171,
      // so max(samples) stays at 171 → endAngle unchanged. Under
      // min/max anchoring (NOT running mean) the new sample only moves
      // the threshold if it sets a new extremum.
      expect(endAfter, closeTo(endBefore, 1e-9));
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
