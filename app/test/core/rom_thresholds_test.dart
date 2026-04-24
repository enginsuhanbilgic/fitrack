import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/core/types.dart';

class _StubBucket implements RomBucketLike {
  @override
  final double observedMinAngle;
  @override
  final double observedMaxAngle;
  const _StubBucket(this.observedMinAngle, this.observedMaxAngle);
}

void main() {
  group('RomThresholds.global', () {
    test('returns the kCurl* constants verbatim', () {
      final t = RomThresholds.global();

      expect(t.startAngle, kCurlStartAngle);
      expect(t.peakAngle, kCurlPeakAngle);
      expect(t.peakExitAngle, kCurlPeakExitAngle);
      expect(t.endAngle, kCurlEndAngle);
      expect(t.source, ThresholdSource.global);
    });
  });

  group('RomThresholds.fromBucket', () {
    test('derives thresholds using base tolerances when not in warmup', () {
      // Average user: deepest flexion 60°, rest at 165°.
      const bucket = _StubBucket(60, 165);

      final t = RomThresholds.fromBucket(bucket);

      // peak = 60 + 15 = 75
      // peakExit = 75 + kCurlPeakExitGap (15) = 90
      // start = 165 - 10 = 155
      // end   = 165 - 25 = 140
      expect(t.peakAngle, 75);
      expect(t.peakExitAngle, 90);
      expect(t.startAngle, 155);
      expect(t.endAngle, 140);
      expect(t.source, ThresholdSource.calibrated);
    });

    test('warmup multiplies every tolerance and tags source as warmup', () {
      const bucket = _StubBucket(60, 165);

      final t = RomThresholds.fromBucket(bucket, warmup: true);

      // multiplier = kProfileWarmupMultiplier (1.5)
      // peak = 60 + (15 * 1.5) = 82.5
      // peakExit = 82.5 + 15 (gap is NOT warmup-scaled) = 97.5
      // start = 165 - (10 * 1.5) = 150
      // end   = 165 - (25 * 1.5) = 127.5
      expect(t.peakAngle, 82.5);
      expect(t.peakExitAngle, 97.5);
      expect(t.startAngle, 150);
      expect(t.endAngle, 127.5);
      expect(t.source, ThresholdSource.warmup);
    });

    test('peakExit is always exactly kCurlPeakExitGap above peakAngle', () {
      const bucket = _StubBucket(50, 170);

      final t1 = RomThresholds.fromBucket(bucket);
      final t2 = RomThresholds.fromBucket(bucket, warmup: true);

      expect(t1.peakExitAngle - t1.peakAngle, kCurlPeakExitGap);
      expect(t2.peakExitAngle - t2.peakAngle, kCurlPeakExitGap);
    });

    test(
      'restricted-ROM user (ex: 90°/130°) still produces a completable FSM',
      () {
        // Post-injury / restricted user — only 40° of usable ROM.
        const bucket = _StubBucket(90, 130);

        final t = RomThresholds.fromBucket(bucket);

        // Raw math would give: peak=105, peakExit=120, end=105 → FSM stuck.
        // Floor must promote endAngle above peakExit by at least one gap.
        expect(t.peakAngle, 105);
        expect(t.peakExitAngle, 120);
        expect(
          t.endAngle,
          greaterThanOrEqualTo(t.peakExitAngle + kCurlPeakExitGap),
        );
        expect(
          t.startAngle,
          greaterThanOrEqualTo(t.peakAngle + kCurlPeakExitGap),
        );
      },
    );

    test(
      'FSM-completability invariants always hold across realistic buckets',
      () {
        // Iterate over a grid of (min, max) bucket values.
        for (var min = 40.0; min <= 120.0; min += 10) {
          for (var max = min + 25; max <= 180.0; max += 10) {
            final bucket = _StubBucket(min, max);
            final t = RomThresholds.fromBucket(bucket);
            // Every derived threshold set must allow a rep to complete.
            expect(
              t.endAngle,
              greaterThan(t.peakExitAngle),
              reason: 'min=$min max=$max yielded uncompletable FSM: $t',
            );
            expect(
              t.startAngle,
              greaterThan(t.peakAngle),
              reason: 'min=$min max=$max yielded uncompletable FSM: $t',
            );
          }
        }
      },
    );
  });

  group('RomThresholds.autoCalibrated', () {
    test('uses base tolerances and tags source as autoCalibrated', () {
      const bucket = _StubBucket(60, 165);

      final t = RomThresholds.autoCalibrated(bucket);

      expect(t.peakAngle, 75);
      expect(t.startAngle, 155);
      expect(t.endAngle, 140);
      expect(t.source, ThresholdSource.autoCalibrated);
    });
  });

  group('RomThresholds.toString', () {
    test('includes all four angles and the source label', () {
      final s = RomThresholds.global().toString();

      expect(s, contains('start=160.0'));
      expect(s, contains('peak=70.0'));
      expect(s, contains('peakExit=85.0'));
      expect(s, contains('end=140.0'));
      expect(s, contains('src=global'));
    });
  });
}
