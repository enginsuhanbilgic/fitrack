/// Tests for `PushUpRomDefaults` and `PushUpRomThresholdSet.applySensitivity`.
///
/// Post-2026-05-14 contract: every factory returns the **High anchor**;
/// sensitivity is applied as a post-pass via [PushUpRomThresholdSet.applySensitivity].
/// `defaults` is preserved as a back-compat alias and now points at the High
/// anchor (pre-2026-05-14 it pointed at Medium).
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/push_up_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PushUpRomDefaults anchor (High)', () {
    test('anchor reproduces today\'s High-tier numbers bit-for-bit', () {
      const anchor = PushUpRomDefaults.anchor;
      expect(anchor.startAngle, 165);
      expect(anchor.bottomAngle, 85);
      expect(anchor.endAngle, 163);
      expect(anchor.shallowRepMaxAngle, 125);
    });

    test(
      'defaults alias points at the High anchor (contract changed 2026-05-14)',
      () {
        expect(
          PushUpRomDefaults.defaults.startAngle,
          PushUpRomDefaults.anchor.startAngle,
        );
        expect(
          PushUpRomDefaults.defaults.bottomAngle,
          PushUpRomDefaults.anchor.bottomAngle,
        );
        expect(
          PushUpRomDefaults.defaults.endAngle,
          PushUpRomDefaults.anchor.endAngle,
        );
        expect(
          PushUpRomDefaults.defaults.shallowRepMaxAngle,
          PushUpRomDefaults.anchor.shallowRepMaxAngle,
        );
      },
    );
  });

  group('PushUpRomDefaults.forSensitivity', () {
    test('high returns the anchor unchanged (identity)', () {
      final high = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.high);
      expect(high.startAngle, PushUpRomDefaults.anchor.startAngle);
      expect(high.bottomAngle, PushUpRomDefaults.anchor.bottomAngle);
      expect(high.endAngle, PushUpRomDefaults.anchor.endAngle);
      expect(
        high.shallowRepMaxAngle,
        PushUpRomDefaults.anchor.shallowRepMaxAngle,
      );
    });

    test('medium reproduces today\'s Medium-baseline numbers bit-for-bit', () {
      final med = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.medium);
      // Pre-2026-05-14 Medium tuple — preserved via looseness deltas
      // (dStart=-5, dBottom=+5, dEnd=-3, dShallow=+5) applied to the anchor.
      expect(med.startAngle, kPushUpStartAngle);
      expect(med.bottomAngle, kPushUpBottomAngle);
      expect(med.endAngle, kPushUpEndAngle);
      expect(med.shallowRepMaxAngle, kPushUpShallowRepMaxAngle);
    });

    test('high tier is stricter than medium across all four gates', () {
      final med = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.medium);
      final high = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.high);
      expect(high.startAngle, greaterThan(med.startAngle));
      expect(high.bottomAngle, lessThan(med.bottomAngle));
      expect(high.endAngle, greaterThan(med.endAngle));
      expect(high.shallowRepMaxAngle, lessThan(med.shallowRepMaxAngle));
    });

    test('every tier satisfies the FSM invariant start >= end > bottom', () {
      for (final s in FeedbackSensitivity.values) {
        final t = PushUpRomDefaults.forSensitivity(s);
        expect(t.startAngle, greaterThanOrEqualTo(t.endAngle), reason: '$s');
        expect(t.endAngle, greaterThan(t.bottomAngle), reason: '$s');
      }
    });

    test('shallow gate sits above bottom in every tier', () {
      for (final s in FeedbackSensitivity.values) {
        final t = PushUpRomDefaults.forSensitivity(s);
        expect(t.shallowRepMaxAngle, greaterThan(t.bottomAngle), reason: '$s');
      }
    });
  });

  group('PushUpRomThresholdSet.applySensitivity (post-pass)', () {
    test('idempotent on High', () {
      const anchor = PushUpRomDefaults.anchor;
      final once = anchor.applySensitivity(FeedbackSensitivity.high);
      final twice = once.applySensitivity(FeedbackSensitivity.high);
      expect(twice.startAngle, once.startAngle);
      expect(twice.bottomAngle, once.bottomAngle);
      expect(twice.endAngle, once.endAngle);
      expect(twice.shallowRepMaxAngle, once.shallowRepMaxAngle);
    });

    test('medium applies looseness deltas (-5, +5, -3, +5)', () {
      const anchor = PushUpRomDefaults.anchor;
      final med = anchor.applySensitivity(FeedbackSensitivity.medium);
      expect(med.startAngle, anchor.startAngle - 5);
      expect(med.bottomAngle, anchor.bottomAngle + 5);
      expect(med.endAngle, anchor.endAngle - 3);
      expect(med.shallowRepMaxAngle, anchor.shallowRepMaxAngle + 5);
    });
  });
}
