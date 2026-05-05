import 'dart:math' as math;

import 'package:fitrack/engine/curl/dtw_scorer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final scorer = DtwScorer();

  group('DtwScorer — identity', () {
    test('identical series → similarity 1.0', () {
      final series = List<double>.generate(32, (i) => 160.0 - i * 3.5);
      final result = scorer.score(series, series);
      expect(result.similarity, closeTo(1.0, 0.001));
    });
  });

  group('DtwScorer — dissimilar series', () {
    test('full-period sine vs monotone ramp → similarity below 0.70', () {
      // A full sine wave has two direction reversals; a ramp has none.
      // After normalization both span [0,1] but the warp path cannot reconcile
      // the frequency difference — empirically scores ~0.64 with band=8.
      final sine = List<double>.generate(
        64,
        (i) => math.sin(i / 63.0 * math.pi * 2),
      );
      final ramp = List<double>.generate(64, (i) => i.toDouble());
      final result = scorer.score(sine, ramp);
      expect(result.similarity, lessThan(0.70));
    });
  });

  group('DtwScorer — time-warped same shape', () {
    test('same arc at different speeds → high similarity', () {
      // Normal-speed rep: 32 samples describing a curl arc.
      final normal = List<double>.generate(32, (i) {
        final t = i / 31.0;
        // Arc: start 160°, peak ~40° at midpoint, return 160°.
        return 160.0 - 120.0 * (1.0 - (2.0 * t - 1.0).abs());
      });
      // Slow-speed: 64 samples, same shape.
      final slow = List<double>.generate(64, (i) {
        final t = i / 63.0;
        return 160.0 - 120.0 * (1.0 - (2.0 * t - 1.0).abs());
      });
      // DTW should align them and yield high similarity.
      final result = scorer.score(normal, slow);
      expect(result.similarity, greaterThan(0.70));
    });
  });

  group('DtwScorer — flat series guard', () {
    test('flat candidate (zero range) does not crash', () {
      final flat = List<double>.filled(32, 90.0);
      final reference = List<double>.generate(32, (i) => i.toDouble());
      expect(() => scorer.score(flat, reference), returnsNormally);
    });

    test('flat reference (zero range) does not crash', () {
      final candidate = List<double>.generate(32, (i) => i.toDouble());
      final flat = List<double>.filled(32, 90.0);
      expect(() => scorer.score(candidate, flat), returnsNormally);
    });

    test('both flat → does not crash, similarity is valid', () {
      final flat = List<double>.filled(32, 90.0);
      final result = scorer.score(flat, flat);
      expect(result.similarity, inInclusiveRange(0.0, 1.0));
    });
  });

  group('DtwScorer — too-short series', () {
    test('single-sample candidate → similarity 0', () {
      final candidate = [90.0];
      final reference = List<double>.generate(32, (i) => i.toDouble());
      final result = scorer.score(candidate, reference);
      expect(result.similarity, 0.0);
      expect(result.rawDistance, double.infinity);
    });

    test('empty candidate → similarity 0', () {
      final result = scorer.score(
        [],
        List<double>.generate(32, (i) => i.toDouble()),
      );
      expect(result.similarity, 0.0);
    });
  });

  group('DtwScorer — output range', () {
    test('similarity is always in [0, 1]', () {
      final pairs = [
        (
          List<double>.generate(20, (i) => i * 5.0),
          List<double>.generate(40, (i) => 100.0 - i * 2.0),
        ),
        ([30.0, 90.0, 150.0, 90.0, 30.0], [160.0, 40.0, 160.0]),
      ];
      for (final (c, r) in pairs) {
        final s = scorer.score(c, r).similarity;
        expect(s, inInclusiveRange(0.0, 1.0), reason: 'c=$c r=$r');
      }
    });
  });
}
