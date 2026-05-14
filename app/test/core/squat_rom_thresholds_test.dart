/// Unit tests for the sensitivity-aware squat ROM threshold factory.
///
/// Post-2026-05-14 contract: every factory returns the **High anchor**;
/// sensitivity is applied as a post-pass via
/// [SquatRomThresholdSet.applySensitivity]. The pre-2026-05-14
/// `forSensitivity` factory is preserved as a back-compat helper that wraps
/// the new pattern (returns High anchor then chains `.applySensitivity(s)`).
///
/// Pins:
///   - `forSensitivity(high)` returns today's High constants (165 / 88 / 163).
///   - `forSensitivity(medium)` returns today's Medium-baseline numbers
///     (160 / 90 / 160) via the looseness deltas (-5, +2, -3) applied to the
///     High anchor.
///   - `SquatRomDefaults.defaults` now points at the High anchor (contract
///     change). Pre-2026-05-14 it pointed at the Medium-baseline tuple.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SquatRomThresholdSet.anchor (High)', () {
    test('matches research-derived High constants bit-for-bit', () {
      const a = SquatRomThresholdSet.anchor;
      expect(a.startAngle, kSquatStartAngleHigh);
      expect(a.startAngle, 165.0);
      expect(a.bottomAngle, kSquatBottomAngleHigh);
      expect(a.bottomAngle, 88.0);
      expect(a.endAngle, kSquatEndAngleHigh);
      expect(a.endAngle, 163.0);
    });

    test('SquatRomDefaults.defaults aliases the High anchor', () {
      expect(
        SquatRomDefaults.defaults.startAngle,
        SquatRomThresholdSet.anchor.startAngle,
      );
      expect(
        SquatRomDefaults.defaults.bottomAngle,
        SquatRomThresholdSet.anchor.bottomAngle,
      );
      expect(
        SquatRomDefaults.defaults.endAngle,
        SquatRomThresholdSet.anchor.endAngle,
      );
    });

    test(
      'SquatRomDefaults.anchor and SquatRomThresholdSet.anchor are the same tuple',
      () {
        expect(
          SquatRomDefaults.anchor.startAngle,
          SquatRomThresholdSet.anchor.startAngle,
        );
        expect(
          SquatRomDefaults.anchor.bottomAngle,
          SquatRomThresholdSet.anchor.bottomAngle,
        );
        expect(
          SquatRomDefaults.anchor.endAngle,
          SquatRomThresholdSet.anchor.endAngle,
        );
      },
    );
  });

  group('SquatRomThresholdSet.applySensitivity (post-pass)', () {
    test('high is identity on the anchor', () {
      final t = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.high,
      );
      expect(t.startAngle, SquatRomThresholdSet.anchor.startAngle);
      expect(t.bottomAngle, SquatRomThresholdSet.anchor.bottomAngle);
      expect(t.endAngle, SquatRomThresholdSet.anchor.endAngle);
    });

    test(
      'medium applies looseness deltas (-5, +2, -3) → Medium-baseline tuple',
      () {
        final t = SquatRomThresholdSet.anchor.applySensitivity(
          FeedbackSensitivity.medium,
        );
        // (165-5, 88+2, 163-3) == (160, 90, 160) == today's Medium-baseline.
        expect(t.startAngle, kSquatStartAngle);
        expect(t.bottomAngle, kSquatBottomAngle);
        expect(t.endAngle, kSquatEndAngle);
        expect(t.startAngle, 160.0);
        expect(t.bottomAngle, 90.0);
        expect(t.endAngle, 160.0);
      },
    );

    test('idempotent on High', () {
      final once = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.high,
      );
      final twice = once.applySensitivity(FeedbackSensitivity.high);
      expect(twice.startAngle, once.startAngle);
      expect(twice.bottomAngle, once.bottomAngle);
      expect(twice.endAngle, once.endAngle);
    });

    test('Medium FSM invariant: start > end > bottom', () {
      final t = SquatRomThresholdSet.anchor.applySensitivity(
        FeedbackSensitivity.medium,
      );
      expect(t.startAngle, greaterThanOrEqualTo(t.endAngle));
      expect(t.endAngle, greaterThan(t.bottomAngle));
    });
  });

  group('SquatRomThresholdSet.forSensitivity (back-compat wrapper)', () {
    test('high → research-derived gates (165 / 88 / 163)', () {
      final t = SquatRomThresholdSet.forSensitivity(FeedbackSensitivity.high);
      expect(t.startAngle, kSquatStartAngleHigh);
      expect(t.bottomAngle, kSquatBottomAngleHigh);
      expect(t.endAngle, kSquatEndAngleHigh);
    });

    test(
      'medium reproduces today\'s Medium-baseline tuple (160 / 90 / 160)',
      () {
        final t = SquatRomThresholdSet.forSensitivity(
          FeedbackSensitivity.medium,
        );
        expect(t.startAngle, kSquatStartAngle);
        expect(t.bottomAngle, kSquatBottomAngle);
        expect(t.endAngle, kSquatEndAngle);
      },
    );

    test(
      'high vs medium differ on every gate with correct strictness ordering',
      () {
        final hi = SquatRomThresholdSet.forSensitivity(
          FeedbackSensitivity.high,
        );
        final mid = SquatRomThresholdSet.forSensitivity(
          FeedbackSensitivity.medium,
        );
        expect(hi.startAngle, greaterThan(mid.startAngle));
        expect(hi.endAngle, greaterThan(mid.endAngle));
        expect(hi.bottomAngle, lessThan(mid.bottomAngle));
      },
    );
  });

  group('SquatRomDefaults.forVariantAndSensitivity', () {
    test('variant-agnostic today: same result for bodyweight and HBBS', () {
      for (final s in FeedbackSensitivity.values) {
        final bw = SquatRomDefaults.forVariantAndSensitivity(
          SquatVariant.bodyweight,
          s,
        );
        final hbbs = SquatRomDefaults.forVariantAndSensitivity(
          SquatVariant.highBarBackSquat,
          s,
        );
        expect(bw.startAngle, hbbs.startAngle);
        expect(bw.bottomAngle, hbbs.bottomAngle);
        expect(bw.endAngle, hbbs.endAngle);
      }
    });

    test('delegates to anchor + applySensitivity', () {
      for (final s in FeedbackSensitivity.values) {
        final viaVariant = SquatRomDefaults.forVariantAndSensitivity(
          SquatVariant.bodyweight,
          s,
        );
        final viaAnchor = SquatRomThresholdSet.anchor.applySensitivity(s);
        expect(viaVariant.startAngle, viaAnchor.startAngle);
        expect(viaVariant.bottomAngle, viaAnchor.bottomAngle);
        expect(viaVariant.endAngle, viaAnchor.endAngle);
      }
    });
  });
}
