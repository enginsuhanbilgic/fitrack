/// Format-contract tests for `formatPushUpRepLine`.
///
/// The format string is consumed by an offline Python regex
/// (`_PUSHUP_REP_RE` in `derive_pushup_thresholds_from_telemetry.py`).
/// These tests pin the exact emitted shape so a regression in the Dart
/// formatter is caught here, not at the next attempt to derive thresholds
/// from a session paste.
///
/// Pure-Dart — uses `flutter_test` only for `group` / `test` / `expect`
/// assertions (no `pumpWidget`, no widget-test surface). The helper is a
/// top-level pure function. Satisfies the project's "no widget tests"
/// hard rule by construction.
library;

import 'package:fitrack/view_models/telemetry/pushup_rep_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatPushUpRepLine', () {
    test('emits all three fields in fixed order with toStringAsFixed(2)', () {
      final line = formatPushUpRepLine(
        repIndex: 1,
        minElbowAngle: 88.3456,
        maxElbowAngle: 162.7890,
      );
      expect(line, 'rep=1 min_elbow=88.35 max_elbow=162.79');
    });

    test('emits literal "null" string when minElbowAngle is null', () {
      // The Python parser anchors on a fixed-order token sequence — null
      // MUST appear as the literal string, never an omitted field.
      final line = formatPushUpRepLine(
        repIndex: 7,
        minElbowAngle: null,
        maxElbowAngle: 162.79,
      );
      expect(line, 'rep=7 min_elbow=null max_elbow=162.79');
    });

    test('emits literal "null" string when maxElbowAngle is null', () {
      final line = formatPushUpRepLine(
        repIndex: 7,
        minElbowAngle: 88.35,
        maxElbowAngle: null,
      );
      expect(line, 'rep=7 min_elbow=88.35 max_elbow=null');
    });

    test('emits both "null" strings when both extremes are null', () {
      final line = formatPushUpRepLine(
        repIndex: 0,
        minElbowAngle: null,
        maxElbowAngle: null,
      );
      expect(line, 'rep=0 min_elbow=null max_elbow=null');
    });

    test('preserves integer rep indices verbatim (no padding)', () {
      // The Python regex captures `\d+` — any zero-padding would break
      // the join with companion telemetry lines that use the same
      // monotonic index.
      final line = formatPushUpRepLine(
        repIndex: 142,
        minElbowAngle: 90.0,
        maxElbowAngle: 160.0,
      );
      expect(line.startsWith('rep=142 '), isTrue);
    });

    test('matches the Python parser regex shape', () {
      // Sanity check: confirm the emitted line conforms to a Dart-side
      // mirror of `_PUSHUP_REP_RE`. Any change here implies a
      // coordinated change to the Python regex in
      // `derive_pushup_thresholds_from_telemetry.py`.
      final mirror = RegExp(
        r'^rep=\d+ '
        r'min_elbow=([0-9.]+|null) '
        r'max_elbow=([0-9.]+|null)$',
      );
      final lines = <String>[
        formatPushUpRepLine(
          repIndex: 1,
          minElbowAngle: 88.0,
          maxElbowAngle: 162.0,
        ),
        formatPushUpRepLine(
          repIndex: 2,
          minElbowAngle: null,
          maxElbowAngle: 162.0,
        ),
        formatPushUpRepLine(
          repIndex: 3,
          minElbowAngle: 88.0,
          maxElbowAngle: null,
        ),
        formatPushUpRepLine(
          repIndex: 4,
          minElbowAngle: null,
          maxElbowAngle: null,
        ),
      ];
      for (final line in lines) {
        expect(mirror.hasMatch(line), isTrue, reason: 'no match: $line');
      }
    });
  });
}
