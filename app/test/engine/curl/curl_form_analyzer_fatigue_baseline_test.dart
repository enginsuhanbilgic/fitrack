/// Tests for the WP5.4 historical-fatigue-baseline extension.
///
/// Existing fatigue coverage in `curl_form_analyzer_test.dart` drives the
/// detection via real `Future.delayed` timing. Here we only care about the
/// baseline math — the `max(firstAvg, historicalMedian)` decision — so tests
/// inject `_concentricDurations` indirectly via real waits but keep those
/// waits small. Historical data is plugged directly into the constructor
/// (plain `List<Duration>`, no wall-clock needed).
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_form_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

import '_pose_fixtures.dart';

/// Drive the analyzer through `N` full reps where the concentric phase waits
/// `concentricMsForIndex(i)` before `onPeakReached()`. Returns the analyzer.
Future<CurlFormAnalyzer> driveReps(
  CurlFormAnalyzer a, {
  required int count,
  required int Function(int) concentricMsForIndex,
}) async {
  for (var i = 0; i < count; i++) {
    a.onRepStart(buildPose());
    await Future<void>.delayed(Duration(milliseconds: concentricMsForIndex(i)));
    a.onPeakReached();
    a.onEccentricStart();
    a.onRepEnd();
  }
  return a;
}

void main() {
  group('CurlFormAnalyzer historical fatigue baseline', () {
    test(
      'empty historical list → backward-compat with pre-WP5.4 (collapses to firstAvg)',
      () async {
        // No historical data. Classic fatigue fire: first 3 reps fast (20ms),
        // last 3 slow (60ms) → lastAvg/firstAvg = 3.0 > 1.4.
        final a = CurlFormAnalyzer();
        await driveReps(
          a,
          count: kFatigueMinReps,
          concentricMsForIndex: (i) => i < 3 ? 20 : 60,
        );
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
        expect(a.fatigueDetected, isTrue);
      },
    );

    test(
      'historical median < firstAvg → baseline collapses to firstAvg, fires the same',
      () async {
        // Historical reps are FAST (20ms median). In-session first-window avg
        // is 60ms; last-window 180ms. max(60, 20) = 60. 180/60 = 3 > 1.4.
        final a = CurlFormAnalyzer(
          historicalConcentricDurations: const [
            Duration(milliseconds: 18),
            Duration(milliseconds: 22),
            Duration(milliseconds: 20),
          ],
        );
        await driveReps(
          a,
          count: kFatigueMinReps,
          concentricMsForIndex: (i) => i < 3 ? 60 : 180,
        );
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
      },
    );

    test(
      'historical median > firstAvg → baseline RAISED, fires earlier on reps that are still slower than baseline',
      () async {
        // User historically curls at 300ms concentric. Today they warm up
        // slowly (firstAvg ~80ms) then actually curl at 500ms late.
        // Pre-WP5.4: baseline = 80, 500/80 = 6.25 → fires.
        // WP5.4: baseline = max(80, 300) = 300, 500/300 = 1.67 → still > 1.4, fires.
        // Both baselines agree here; this test confirms the raised baseline
        // DOESN'T prevent a legitimate fire (no false negative regression).
        final a = CurlFormAnalyzer(
          historicalConcentricDurations: List.generate(
            5,
            (_) => const Duration(milliseconds: 300),
          ),
        );
        await driveReps(
          a,
          count: kFatigueMinReps,
          concentricMsForIndex: (i) => i < 3 ? 80 : 500,
        );
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
      },
    );

    test(
      'historical median > firstAvg guards against a WARM-UP false positive',
      () async {
        // User's true baseline is 300ms. Today they warm up artificially slow
        // (firstAvg ~100ms) then settle at their real pace (~350ms).
        // Pre-WP5.4: baseline = 100, 350/100 = 3.5 > 1.4 → FALSE POSITIVE fatigue.
        // WP5.4: baseline = max(100, 300) = 300, 350/300 = 1.17 < 1.4 → no fire.
        final a = CurlFormAnalyzer(
          historicalConcentricDurations: List.generate(
            5,
            (_) => const Duration(milliseconds: 300),
          ),
        );
        await driveReps(
          a,
          count: kFatigueMinReps,
          concentricMsForIndex: (i) => i < 3 ? 100 : 350,
        );
        expect(
          a.consumeCompletionErrors(),
          isNot(contains(FormError.fatigue)),
          reason: 'historical baseline must absorb warm-up-slow artifacts',
        );
        expect(a.fatigueDetected, isFalse);
      },
    );

    test(
      'does NOT fire below kFatigueMinReps regardless of historical data',
      () async {
        final a = CurlFormAnalyzer(
          historicalConcentricDurations: const [Duration(milliseconds: 50)],
        );
        await driveReps(
          a,
          count: kFatigueMinReps - 1, // one short
          concentricMsForIndex: (i) => i < 2 ? 20 : 200,
        );
        expect(
          a.consumeCompletionErrors(),
          isNot(contains(FormError.fatigue)),
          reason: 'fatigue detector must require ≥ kFatigueMinReps reps',
        );
      },
    );

    test(
      'lastConcentricDuration exposes the most recent onPeakReached timing',
      () async {
        final a = CurlFormAnalyzer();
        expect(a.lastConcentricDuration, isNull);

        a.onRepStart(buildPose());
        await Future<void>.delayed(const Duration(milliseconds: 25));
        a.onPeakReached();

        expect(a.lastConcentricDuration, isNotNull);
        expect(
          a.lastConcentricDuration!.inMilliseconds,
          greaterThanOrEqualTo(20),
        );
      },
    );

    test(
      'historical median uses the middle element (not mean) — robust to 1 outlier',
      () async {
        // Mean of [50, 100, 1000] = 383; median = 100.
        // firstAvg = 60, lastAvg = 200. max(60, 100) = 100. 200/100 = 2.0 > 1.4 → fires.
        // If the baseline had used the mean (383), 200/383 = 0.52 < 1.4 →
        // fatigue would have been suppressed. This test locks the median choice.
        final a = CurlFormAnalyzer(
          historicalConcentricDurations: const [
            Duration(milliseconds: 50),
            Duration(milliseconds: 100),
            Duration(milliseconds: 1000),
          ],
        );
        await driveReps(
          a,
          count: kFatigueMinReps,
          concentricMsForIndex: (i) => i < 3 ? 60 : 200,
        );
        expect(a.consumeCompletionErrors(), contains(FormError.fatigue));
      },
    );
  });
}
