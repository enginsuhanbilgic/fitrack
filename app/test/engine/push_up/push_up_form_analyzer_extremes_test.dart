/// Unit tests for the per-rep elbow-extreme tracking added to
/// `PushUpFormAnalyzer` for the telemetry-derived ROM tuning pipeline.
///
/// Scope: the snapshot lifecycle of `_minElbowAngle` / `_maxElbowAngleThisRep`
/// — captured on every `trackAngle` / `trackMaxElbow` call, copied into
/// `lastRepMinElbowAngle` / `lastRepMaxElbowAngle` on
/// `consumeCompletionErrors`, then cleared. The `PushUpStrategy` integration
/// tests in `push_up_strategy_test.dart` cover the FSM-driven call sites.
///
/// Pure-logic — no `pumpWidget`, no async machinery. Uses `flutter_test`
/// only for `group / test / expect`.
library;

import 'package:fitrack/engine/push_up/push_up_form_analyzer.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

PoseResult _emptyPose() =>
    const PoseResult(inferenceTime: Duration(milliseconds: 10), landmarks: []);

void main() {
  group('PushUpFormAnalyzer — last-rep elbow extremes', () {
    test('lastRepMin/Max are null before any rep commits', () {
      final a = PushUpFormAnalyzer();
      expect(a.lastRepMinElbowAngle, isNull);
      expect(a.lastRepMaxElbowAngle, isNull);
    });

    test('snapshot captures the rep\'s min/max on consumeCompletionErrors', () {
      final a = PushUpFormAnalyzer();
      a.onRepStart(_emptyPose());
      // Walk through a synthetic rep: 160 → 90 → 160. The min-tracker
      // should land on 90, the max-tracker on 160.
      a
        ..trackAngle(160)
        ..trackMaxElbow(160)
        ..trackAngle(120)
        ..trackMaxElbow(120)
        ..trackAngle(90)
        ..trackMaxElbow(90)
        ..trackAngle(120)
        ..trackMaxElbow(120)
        ..trackAngle(160)
        ..trackMaxElbow(160);

      a.consumeCompletionErrors();

      expect(a.lastRepMinElbowAngle, 90.0);
      expect(a.lastRepMaxElbowAngle, 160.0);
    });

    test(
      'next onRepStart clears the in-progress trackers but keeps the snapshot',
      () {
        final a = PushUpFormAnalyzer();
        a.onRepStart(_emptyPose());
        a
          ..trackAngle(95)
          ..trackMaxElbow(165);
        a.consumeCompletionErrors();

        // Snapshot survives until the NEXT rep commits.
        a.onRepStart(_emptyPose());
        expect(a.lastRepMinElbowAngle, 95.0);
        expect(a.lastRepMaxElbowAngle, 165.0);

        a
          ..trackAngle(80)
          ..trackMaxElbow(170);
        a.consumeCompletionErrors();

        // Now overwritten with rep 2's extremes.
        expect(a.lastRepMinElbowAngle, 80.0);
        expect(a.lastRepMaxElbowAngle, 170.0);
      },
    );

    test('reset() clears the snapshot fields too', () {
      final a = PushUpFormAnalyzer();
      a.onRepStart(_emptyPose());
      a
        ..trackAngle(85)
        ..trackMaxElbow(168);
      a.consumeCompletionErrors();
      expect(a.lastRepMinElbowAngle, isNotNull);
      expect(a.lastRepMaxElbowAngle, isNotNull);

      a.reset();
      expect(a.lastRepMinElbowAngle, isNull);
      expect(a.lastRepMaxElbowAngle, isNull);
    });

    test('trackMaxElbow ignores values lower than the current max', () {
      // Independence from `trackAngle`: max tracker only ratchets up;
      // min tracker only ratchets down. They observe the same stream
      // of frames but maintain orthogonal extremes.
      final a = PushUpFormAnalyzer();
      a.onRepStart(_emptyPose());
      a
        ..trackAngle(160)
        ..trackMaxElbow(160)
        ..trackAngle(120)
        ..trackMaxElbow(120) // doesn't override the 160 ceiling
        ..trackAngle(90)
        ..trackMaxElbow(90);
      a.consumeCompletionErrors();

      expect(a.lastRepMaxElbowAngle, 160.0);
      expect(a.lastRepMinElbowAngle, 90.0);
    });

    test('snapshot is null when no frames were tracked for that dimension', () {
      // A rep that commits without ever calling `trackMaxElbow` (e.g.
      // a degenerate analyzer-skipped path) leaves the snapshot null —
      // the telemetry emitter writes the literal `"null"` for this case.
      final a = PushUpFormAnalyzer();
      a.onRepStart(_emptyPose());
      a.consumeCompletionErrors();
      expect(a.lastRepMinElbowAngle, isNull);
      expect(a.lastRepMaxElbowAngle, isNull);
    });
  });
}
