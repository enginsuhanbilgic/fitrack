/// Tests for `PushUpRomDefaults.forSensitivity` — the sensitivity-keyed
/// cold-start ROM accessor added 2026-05-13.
///
/// The values returned here are still hand-tuned; the follow-up
/// telemetry-derivation PR replaces them with values produced by
/// `tools/dataset_analysis/scripts/derive_pushup_thresholds_from_telemetry.py`.
/// These tests pin the API shape and the relative ordering of tiers
/// (high = stricter than medium) so a regression in the placeholder
/// constants is caught here.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/push_up_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PushUpRomDefaults.forSensitivity', () {
    test('medium tier matches the legacy hand-tuned constants', () {
      // Bit-for-bit identical to the pre-refactor `defaults` so any
      // call site that hasn't migrated to `forSensitivity` sees no
      // behavior change.
      final med = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.medium);
      expect(med.startAngle, kPushUpStartAngle);
      expect(med.bottomAngle, kPushUpBottomAngle);
      expect(med.endAngle, kPushUpEndAngle);
      expect(med.shallowRepMaxAngle, kPushUpShallowRepMaxAngle);
    });

    test('defaults is the same tuple as medium (back-compat alias)', () {
      // `PushUpRomDefaults.defaults` is preserved for migration runway.
      // It must return the medium tuple so legacy consumers behave
      // identically to a fresh-built `forSensitivity(medium)` call.
      final med = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.medium);
      expect(PushUpRomDefaults.defaults.startAngle, med.startAngle);
      expect(PushUpRomDefaults.defaults.bottomAngle, med.bottomAngle);
      expect(PushUpRomDefaults.defaults.endAngle, med.endAngle);
      expect(
        PushUpRomDefaults.defaults.shallowRepMaxAngle,
        med.shallowRepMaxAngle,
      );
    });

    test('high tier is stricter than medium across all four gates', () {
      // Strictness semantics (matches squat's high-tier shape):
      //   startAngle  → HIGHER  (must be more extended to start a rep)
      //   bottomAngle → LOWER   (must descend further to count depth)
      //   endAngle    → HIGHER  (must return more fully)
      //   shallowMax  → LOWER   (less forgiving of partial reps)
      final med = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.medium);
      final high = PushUpRomDefaults.forSensitivity(FeedbackSensitivity.high);

      expect(high.startAngle, greaterThan(med.startAngle));
      expect(high.bottomAngle, lessThan(med.bottomAngle));
      expect(high.endAngle, greaterThan(med.endAngle));
      expect(high.shallowRepMaxAngle, lessThan(med.shallowRepMaxAngle));
    });

    test('every tier satisfies the FSM invariant start >= end > bottom', () {
      // FSM contract — the IDLE → DESCENDING transition uses
      // `smoothed < startAngle` (strict) and ASCENDING → IDLE uses
      // `smoothed >= endAngle` (non-strict), so `start == end` is
      // legal (matches the existing `kPushUpStartAngle == kPushUpEndAngle`
      // medium-tier shape). What is NOT legal is `end <= bottom` — the
      // rep would commit at the same depth it's still descending into.
      for (final s in FeedbackSensitivity.values) {
        final t = PushUpRomDefaults.forSensitivity(s);
        expect(
          t.startAngle,
          greaterThanOrEqualTo(t.endAngle),
          reason: '$s: start (${t.startAngle}) < end (${t.endAngle})',
        );
        expect(
          t.endAngle,
          greaterThan(t.bottomAngle),
          reason: '$s: end (${t.endAngle}) ≤ bottom (${t.bottomAngle})',
        );
      }
    });

    test('shallow gate sits above bottom in every tier', () {
      // Shallow == "the rep reached at least this depth before reversing".
      // Must be deeper than the no-rep abort but shallower than the
      // counted-rep depth — i.e. shallowMax > bottom.
      for (final s in FeedbackSensitivity.values) {
        final t = PushUpRomDefaults.forSensitivity(s);
        expect(
          t.shallowRepMaxAngle,
          greaterThan(t.bottomAngle),
          reason:
              '$s: shallowMax (${t.shallowRepMaxAngle}) ≤ '
              'bottom (${t.bottomAngle})',
        );
      }
    });
  });
}
