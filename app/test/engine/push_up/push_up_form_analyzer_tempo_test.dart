/// Unit tests for `PushUpFormAnalyzer` tempo/fatigue (2026-05-16,
/// curl-parity). DESCENDING = eccentric (lowering), ASCENDING = concentric
/// (press). The analyzer takes `now` explicitly via
/// onDescentStart/onAscentStart/onAscentEnd, so these tests drive synthetic
/// timestamps with zero wall-clock delay.
///
/// IMPORTANT — push-up does NOT have the squat one-rep window-feed lag.
/// `onAscentEnd` appends to `_ascentDurations` directly (push-up has no
/// half-rep depth veto, so no deferred `commitAscentToWindow`). The window
/// is therefore evaluable on the SAME rep's `consumeCompletionErrors` —
/// a 3-deep window fires on the 3rd rep, a 6-deep on the 6th. See SKILLS
/// §6a for why squat and push-up legitimately differ here.
library;

import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/push_up/push_up_form_analyzer.dart';
import 'package:fitrack/models/pose_result.dart';
import 'package:flutter_test/flutter_test.dart';

PoseResult _emptyPose() =>
    const PoseResult(inferenceTime: Duration(milliseconds: 10), landmarks: []);

void main() {
  final t0 = DateTime(2026, 5, 16, 12);

  PushUpFormAnalyzer make({List<Duration> historical = const []}) =>
      PushUpFormAnalyzer(historicalConcentricDurations: historical);

  // Drive one full rep. Deep bottom (trackAngle 70) so pushUpShortRom
  // never confounds the tempo assertions. Returns the commit errors.
  List<FormError> runRep(
    PushUpFormAnalyzer a, {
    required Duration descent,
    required Duration ascent,
    required DateTime start,
  }) {
    a.onRepStart(_emptyPose());
    a.onDescentStart(start);
    a
      ..trackAngle(160)
      ..trackMaxElbow(160)
      ..trackAngle(70) // deep — below bottom gate, no shortRom
      ..trackMaxElbow(160);
    final ascentStart = start.add(descent);
    a.onAscentStart(ascentStart);
    a.onAscentEnd(ascentStart.add(ascent));
    return a.consumeCompletionErrors();
  }

  group('Push-up tempo / fatigue', () {
    test('fast descent fires pushUpEccentricTooFast; slow does not', () {
      final fast = make();
      expect(
        runRep(
          fast,
          descent: const Duration(milliseconds: 300), // < 0.5s floor
          ascent: const Duration(milliseconds: 700),
          start: t0,
        ),
        contains(FormError.pushUpEccentricTooFast),
      );
      final slow = make();
      expect(
        runRep(
          slow,
          descent: const Duration(milliseconds: 800), // > 0.5s
          ascent: const Duration(milliseconds: 700),
          start: t0,
        ),
        isNot(contains(FormError.pushUpEccentricTooFast)),
      );
    });

    test('fast ascent fires pushUpConcentricTooFast; slow does not', () {
      final fast = make();
      expect(
        runRep(
          fast,
          descent: const Duration(milliseconds: 800),
          ascent: const Duration(milliseconds: 250), // < 0.4s floor
          start: t0,
        ),
        contains(FormError.pushUpConcentricTooFast),
      );
      final slow = make();
      expect(
        runRep(
          slow,
          descent: const Duration(milliseconds: 800),
          ascent: const Duration(milliseconds: 600), // > 0.4s
          start: t0,
        ),
        isNot(contains(FormError.pushUpConcentricTooFast)),
      );
    });

    test('wide ascent variance fires pushUpTempoInconsistent (no lag)', () {
      final a = make();
      var start = t0;
      // Reps 1-2 steady; window <3 → no check.
      for (var i = 0; i < 2; i++) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 800),
          ascent: const Duration(milliseconds: 700),
          start: start,
        );
        expect(errs, isNot(contains(FormError.pushUpTempoInconsistent)));
        start = start.add(const Duration(seconds: 5));
      }
      // Rep 3: window = [700,700,1700] (this rep's 1700 IS included —
      // push-up appends in onAscentEnd, before consume). (max−min)/mean
      // = 1000/1033 ≈ 0.97 > 0.30 → FIRES on this same rep.
      final r3 = runRep(
        a,
        descent: const Duration(milliseconds: 800),
        ascent: const Duration(milliseconds: 1700),
        start: start,
      );
      expect(r3, contains(FormError.pushUpTempoInconsistent));
    });

    test('steady ascent does NOT fire pushUpTempoInconsistent', () {
      final a = make();
      var start = t0;
      for (var i = 0; i < 6; i++) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 800),
          ascent: const Duration(milliseconds: 700),
          start: start,
        );
        expect(errs, isNot(contains(FormError.pushUpTempoInconsistent)));
        start = start.add(const Duration(seconds: 5));
      }
    });

    test('pushUpFatigue fires once when press slows past the ratio', () {
      final a = make();
      var start = t0;
      // 3 fast (600ms) then 3 slow (1000ms). No lag: the 6-deep window is
      // complete on rep 6's consume. firstAvg≈600, lastAvg≈1000 →
      // 1000/600 = 1.67 > kPushUpFatigueSlowdownRatio (1.4).
      const plan = [600, 600, 600, 1000, 1000, 1000];
      var fired = 0;
      for (final ms in plan) {
        final errs = runRep(
          a,
          descent: const Duration(milliseconds: 800),
          ascent: Duration(milliseconds: ms),
          start: start,
        );
        if (errs.contains(FormError.pushUpFatigue)) fired++;
        start = start.add(const Duration(seconds: 5));
      }
      expect(fired, 1, reason: 'fatigue is a one-shot per session');
    });

    test('reset() clears tempo/fatigue state (fatigue re-armable)', () {
      const plan = [600, 600, 600, 1000, 1000, 1000];
      final a = make();
      var start = t0;
      var before = 0;
      for (final ms in plan) {
        if (runRep(
          a,
          descent: const Duration(milliseconds: 800),
          ascent: Duration(milliseconds: ms),
          start: start,
        ).contains(FormError.pushUpFatigue)) {
          before++;
        }
        start = start.add(const Duration(seconds: 5));
      }
      expect(before, 1, reason: 'sanity: fatigue tripped pre-reset');

      a.reset();

      var after = 0;
      for (final ms in plan) {
        if (runRep(
          a,
          descent: const Duration(milliseconds: 800),
          ascent: Duration(milliseconds: ms),
          start: start,
        ).contains(FormError.pushUpFatigue)) {
          after++;
        }
        start = start.add(const Duration(seconds: 5));
      }
      expect(
        after,
        1,
        reason: 'reset() must clear _fatigueFired + _ascentDurations',
      );
    });

    test('shallow rep (no ascent phase) skips tempo signals', () {
      // A reversal-before-bottom rep: onAscentStart/onAscentEnd never
      // called → _lastConcentricDuration stays null → no concentric cue,
      // and nothing appended to the rolling window.
      final a = make();
      a.onRepStart(_emptyPose());
      a.onDescentStart(t0);
      a
        ..trackAngle(160)
        ..trackMaxElbow(160)
        ..trackAngle(120) // never reached bottom
        ..trackMaxElbow(160);
      // No onAscentStart / onAscentEnd — reversed early.
      final errs = a.consumeCompletionErrors();
      expect(errs, isNot(contains(FormError.pushUpConcentricTooFast)));
      expect(errs, isNot(contains(FormError.pushUpEccentricTooFast)));
      expect(a.lastConcentricDuration, isNull);
    });
  });
}
