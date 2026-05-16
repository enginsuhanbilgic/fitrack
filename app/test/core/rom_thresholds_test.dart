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
    // Three-tier resolver: telemetry-derived defaults > pipeline-derived (shelved) > legacy.
    // These tests describe behavior under the SHIPPING flag config: telemetry
    // defaults on, pipeline defaults off. If either flag flips, rework the tests
    // (with explicit acknowledgement of the new tier in scope) rather than
    // silently regressing.
    test(
      'telemetry-defaults branch is active under kUseTelemetryRomDefaults',
      () {
        expect(
          kUseTelemetryRomDefaults,
          isTrue,
          reason:
              'Test file assumes the telemetry-defaults branch is enabled. Flip '
              'this precondition if the flag is intentionally set to false.',
        );
      },
    );

    test('front (legacy sentinel) returns invariant-holding thresholds', () {
      // Front view removed 2026-05; the enum is now a view-detector
      // fallback sentinel. RomThresholds.global must still hand the FSM
      // valid thresholds (via the pipeline-tier side fallback in
      // PipelineRomDefaults.forView).
      // ignore: deprecated_member_use
      final t = RomThresholds.global(CurlCameraView.front);
      expect(t.startAngle, greaterThan(t.endAngle));
      expect(t.peakExitAngle, greaterThan(t.peakAngle));
      expect(t.source, ThresholdSource.global);
    });

    test(
      'sideLeft view returns the telemetry-defaults bucket (derived 2026-04-28)',
      () {
        // CurlRomDefaults.sideLeftDefault is now populated from a --from-frames
        // diagnostic session. Medium sensitivity is the no-arg default.
        final t = RomThresholds.global(CurlCameraView.sideLeft);

        expect(t.startAngle, closeTo(159.0, 0.01));
        expect(t.peakAngle, closeTo(136.4, 0.01));
        expect(t.peakExitAngle, closeTo(151.4, 0.01));
        expect(t.endAngle, closeTo(156.4, 0.01));
        expect(t.source, ThresholdSource.global);
      },
    );

    test('sideRight returns same values as sideLeft (bilateral symmetry)', () {
      // Both views use the same 2026-04-28 session data by bilateral symmetry.
      final left = RomThresholds.global(CurlCameraView.sideLeft);
      final right = RomThresholds.global(CurlCameraView.sideRight);

      expect(right.startAngle, left.startAngle);
      expect(right.peakAngle, left.peakAngle);
      expect(right.peakExitAngle, left.peakExitAngle);
      expect(right.endAngle, left.endAngle);
    });

    test('unknown view falls through to legacy', () {
      // Unknown returns null from manual overrides → falls to data-driven
      // (off) → falls to legacy constants. Matches sideLeft/sideRight today.
      final unknown = RomThresholds.global();

      expect(unknown.startAngle, kCurlStartAngle);
      expect(unknown.peakAngle, kCurlPeakAngle);
    });

    test('FSM-completability holds for every cold-start bucket', () {
      for (final v in CurlCameraView.values) {
        final t = RomThresholds.global(v);
        expect(
          t.endAngle,
          greaterThan(t.peakExitAngle),
          reason: 'view=$v produced uncompletable FSM: $t',
        );
        expect(
          t.startAngle,
          greaterThan(t.peakAngle),
          reason: 'view=$v produced uncompletable FSM: $t',
        );
        expect(
          t.peakExitAngle - t.peakAngle,
          closeTo(kCurlPeakExitGap, 0.01),
          reason: 'view=$v violates peakExitGap contract',
        );
      }
    });
  });

  group('RomThresholds.fromBucket', () {
    test('derives thresholds using base tolerances when not in warmup', () {
      // Average user: deepest flexion 60°, rest at 165°.
      const bucket = _StubBucket(60, 165);

      final t = RomThresholds.fromBucket(bucket);

      // Tolerances halved 2026-05-16: peak +7.5, start -5, end -12.5.
      // peak = 60 + 7.5 = 67.5
      // peakExit = 67.5 + kCurlPeakExitGap (15) = 82.5
      // start = 165 - 5 = 160
      // end   = 165 - 12.5 = 152.5
      expect(t.peakAngle, 67.5);
      expect(t.peakExitAngle, 82.5);
      expect(t.startAngle, 160);
      expect(t.endAngle, 152.5);
      expect(t.source, ThresholdSource.calibrated);
    });

    test('warmup multiplies every tolerance and tags source as warmup', () {
      const bucket = _StubBucket(60, 165);

      final t = RomThresholds.fromBucket(bucket, warmup: true);

      // multiplier = kProfileWarmupMultiplier (1.5)
      // Tolerances halved 2026-05-16: peak +7.5, start -5, end -12.5.
      // peak = 60 + (7.5 * 1.5) = 71.25
      // peakExit = 71.25 + 15 (gap is NOT warmup-scaled) = 86.25
      // start = 165 - (5 * 1.5) = 157.5
      // end   = 165 - (12.5 * 1.5) = 146.25
      expect(t.peakAngle, 71.25);
      expect(t.peakExitAngle, 86.25);
      expect(t.startAngle, 157.5);
      expect(t.endAngle, 146.25);
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

        // Tolerances halved 2026-05-16. Raw math: peak=97.5, peakExit=112.5,
        // raw end=117.5 < peakExit+gap(127.5) → FSM stuck without the floor.
        // Floor must promote endAngle above peakExit by at least one gap.
        expect(t.peakAngle, 97.5);
        expect(t.peakExitAngle, 112.5);
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

      // Tolerances halved 2026-05-16: peak +7.5, start -5, end -12.5.
      expect(t.peakAngle, 67.5);
      expect(t.startAngle, 160);
      expect(t.endAngle, 152.5);
      expect(t.source, ThresholdSource.autoCalibrated);
    });
  });

  group('RomThresholds.applySensitivity (post-pass, 2026-05-14)', () {
    // Bucket-derived tuples are High-anchored; applySensitivity loosens
    // them for Medium using Tier-3-style deltas (-5, +10, 0).
    test('high is identity on a calibrated tuple', () {
      const bucket = _StubBucket(60, 165);
      final anchor = RomThresholds.fromBucket(bucket);
      final t = anchor.applySensitivity(FeedbackSensitivity.high);
      expect(t.startAngle, anchor.startAngle);
      expect(t.peakAngle, anchor.peakAngle);
      expect(t.peakExitAngle, anchor.peakExitAngle);
      expect(t.endAngle, anchor.endAngle);
      expect(t.source, ThresholdSource.calibrated);
    });

    test('medium loosens a calibrated tuple by (-8, +12, -6)', () {
      const bucket = _StubBucket(60, 165);
      final anchor = RomThresholds.fromBucket(bucket);
      // anchor (halved tolerances): peak=67.5, peakExit=82.5, start=160, end=152.5
      final t = anchor.applySensitivity(FeedbackSensitivity.medium);
      // _tier3MediumLooseness (-8, +12, -6):
      //   start = 160 - 8   = 152
      //   peak  = 67.5 + 12 = 79.5
      //   end   = 152.5 - 6 = 146.5
      // peakExit re-derived: 79.5 + 15 = 94.5
      // Strict floor: end > peakExit + gap (109.5)? 146.5 > 109.5 ✓
      expect(t.startAngle, 152);
      expect(t.peakAngle, 79.5);
      expect(t.peakExitAngle, 94.5);
      expect(t.endAngle, 146.5);
      // Source survives the post-pass.
      expect(t.source, ThresholdSource.calibrated);
    });

    test('medium loosens an autoCalibrated tuple the same way', () {
      const bucket = _StubBucket(60, 165);
      final anchor = RomThresholds.autoCalibrated(bucket);
      final t = anchor.applySensitivity(FeedbackSensitivity.medium);
      // Same math as the calibrated case above (shared _build + post-pass).
      expect(t.startAngle, 152);
      expect(t.peakAngle, 79.5);
      expect(t.endAngle, 146.5);
      expect(t.source, ThresholdSource.autoCalibrated);
    });

    test('idempotent on High', () {
      const bucket = _StubBucket(60, 165);
      final anchor = RomThresholds.fromBucket(bucket);
      final once = anchor.applySensitivity(FeedbackSensitivity.high);
      final twice = once.applySensitivity(FeedbackSensitivity.high);
      expect(twice.startAngle, once.startAngle);
      expect(twice.peakAngle, once.peakAngle);
      expect(twice.endAngle, once.endAngle);
    });

    test(
      'FSM invariant survives medium loosening across realistic buckets',
      () {
        for (var min = 40.0; min <= 120.0; min += 10) {
          for (var max = min + 25; max <= 180.0; max += 10) {
            final bucket = _StubBucket(min, max);
            final t = RomThresholds.fromBucket(
              bucket,
            ).applySensitivity(FeedbackSensitivity.medium);
            expect(
              t.endAngle,
              greaterThan(t.peakExitAngle),
              reason: 'min=$min max=$max yielded uncompletable Medium FSM: $t',
            );
            expect(
              t.startAngle,
              greaterThan(t.peakAngle),
              reason: 'min=$min max=$max yielded uncompletable Medium FSM: $t',
            );
          }
        }
      },
    );
  });

  group('RomThresholds.globalUnmodified (diagnostic path)', () {
    // The diagnostic short-circuit needs Tier-3 Medium-baseline numbers
    // verbatim — applying sensitivity would make the offline tuning
    // workflow circular. globalUnmodified returns the legacy kCurl*
    // constants directly, regardless of view.
    test('returns the legacy hand-tuned constants exactly', () {
      final t = RomThresholds.globalUnmodified();
      expect(t.startAngle, kCurlStartAngle);
      expect(t.peakAngle, kCurlPeakAngle);
      expect(t.peakExitAngle, kCurlPeakExitAngle);
      expect(t.endAngle, kCurlEndAngle);
      expect(t.source, ThresholdSource.global);
    });

    test('view argument is accepted but does not change the output', () {
      final base = RomThresholds.globalUnmodified();
      for (final v in CurlCameraView.values) {
        final t = RomThresholds.globalUnmodified(v);
        expect(t.startAngle, base.startAngle);
        expect(t.peakAngle, base.peakAngle);
        expect(t.peakExitAngle, base.peakExitAngle);
        expect(t.endAngle, base.endAngle);
      }
    });
  });

  group('RomThresholds.toString', () {
    test('includes all four angles and the source label', () {
      // Use a fixed synthetic threshold set so this test is independent of
      // the live data-driven bucket values (which evolve with the dataset).
      const t = RomThresholds(
        startAngle: 160,
        peakAngle: 70,
        peakExitAngle: 85,
        endAngle: 140,
        source: ThresholdSource.global,
      );

      final s = t.toString();

      expect(s, contains('start=160.0'));
      expect(s, contains('peak=70.0'));
      expect(s, contains('peakExit=85.0'));
      expect(s, contains('end=140.0'));
      expect(s, contains('src=global'));
    });
  });
}
