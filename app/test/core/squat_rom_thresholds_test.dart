/// Unit tests for the sensitivity-aware squat ROM threshold factory.
///
/// Part 1 of the squat pipeline overhaul (2026-05-13). Pins:
///   - `forSensitivity(high)` returns the research-derived High constants
///     (165 / 88 / 163), not the Medium defaults.
///   - `forSensitivity(medium)` returns the existing hand-tuned constants
///     bit-for-bit (160 / 90 / 160). This is the backward-compatibility
///     contract for users on Medium — Part 1 must not regress their FSM.
///   - `forVariantAndSensitivity` is variant-agnostic today (mirrors the
///     existing `forVariant` shape). When per-variant gates land, this
///     test gets a variant axis added.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SquatRomThresholdSet.forSensitivity', () {
    test('high → research-derived gates (165 / 88 / 163)', () {
      final t = SquatRomThresholdSet.forSensitivity(FeedbackSensitivity.high);
      expect(t.startAngle, kSquatStartAngleHigh);
      expect(t.startAngle, 165.0);
      expect(t.bottomAngle, kSquatBottomAngleHigh);
      expect(t.bottomAngle, 88.0);
      expect(t.endAngle, kSquatEndAngleHigh);
      expect(t.endAngle, 163.0);
    });

    test(
      'medium → existing hand-tuned defaults bit-for-bit (160 / 90 / 160)',
      () {
        final t = SquatRomThresholdSet.forSensitivity(
          FeedbackSensitivity.medium,
        );
        // Pin against both the canonical default tuple AND the underlying
        // constants. Both paths must hold — the second protects against a
        // future refactor that quietly diverges defaults from constants.
        expect(t.startAngle, SquatRomDefaults.defaults.startAngle);
        expect(t.bottomAngle, SquatRomDefaults.defaults.bottomAngle);
        expect(t.endAngle, SquatRomDefaults.defaults.endAngle);
        expect(t.startAngle, kSquatStartAngle);
        expect(t.bottomAngle, kSquatBottomAngle);
        expect(t.endAngle, kSquatEndAngle);
      },
    );

    test('high vs medium differ on every gate', () {
      final hi = SquatRomThresholdSet.forSensitivity(FeedbackSensitivity.high);
      final mid = SquatRomThresholdSet.forSensitivity(
        FeedbackSensitivity.medium,
      );
      expect(hi.startAngle, isNot(mid.startAngle));
      expect(hi.bottomAngle, isNot(mid.bottomAngle));
      expect(hi.endAngle, isNot(mid.endAngle));
      // High is stricter on start/end (must reach a fuller extension) and
      // tighter on bottom (must descend deeper).
      expect(hi.startAngle, greaterThan(mid.startAngle));
      expect(hi.endAngle, greaterThan(mid.endAngle));
      expect(hi.bottomAngle, lessThan(mid.bottomAngle));
    });
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

    test('delegates to forSensitivity (same tuple as the factory)', () {
      for (final s in FeedbackSensitivity.values) {
        final viaVariant = SquatRomDefaults.forVariantAndSensitivity(
          SquatVariant.bodyweight,
          s,
        );
        final viaFactory = SquatRomThresholdSet.forSensitivity(s);
        expect(viaVariant.startAngle, viaFactory.startAngle);
        expect(viaVariant.bottomAngle, viaFactory.bottomAngle);
        expect(viaVariant.endAngle, viaFactory.endAngle);
      }
    });
  });
}
