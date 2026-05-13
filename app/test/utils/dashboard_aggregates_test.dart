/// Unit tests for `lib/utils/dashboard_aggregates.dart` — the proxy
/// formulas behind Strain / Recovery / Output and the weekly-volume bars.
library;

import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:fitrack/utils/dashboard_aggregates.dart';
import 'package:flutter_test/flutter_test.dart';

SessionSummary makeSession({
  required int id,
  required DateTime startedAt,
  Duration duration = const Duration(minutes: 5),
  int reps = 20,
  double? quality = 0.85,
  bool fatigue = false,
  ExerciseType exercise = ExerciseType.bicepsCurlSide,
}) => SessionSummary(
  id: id,
  exercise: exercise,
  startedAt: startedAt,
  duration: duration,
  totalReps: reps,
  totalSets: 1,
  averageQuality: quality,
  fatigueDetected: fatigue,
  asymmetryDetected: false,
);

void main() {
  // Anchor "now" at a known weekday so weekly-bar logic is deterministic.
  // 2026-05-13 is a Wednesday → ISO weekday 3 → bars index 2.
  final now = DateTime(2026, 5, 13, 12, 0);

  group('computeStrain', () {
    test('returns 0 with no sessions', () {
      expect(computeStrain(const []), 0.0);
    });

    test('clamps to 21 even with massive volume', () {
      final huge = [
        for (int i = 0; i < 50; i++)
          makeSession(
            id: i,
            startedAt: now.subtract(Duration(days: i % 7)),
            reps: 200,
            duration: const Duration(minutes: 30),
          ),
      ];
      expect(computeStrain(huge), 21.0);
    });

    test('typical light session reads under 5', () {
      final light = [
        makeSession(
          id: 1,
          startedAt: now,
          reps: 30,
          duration: const Duration(minutes: 4),
        ),
      ];
      // raw = 30 * 4 = 120; / 50 = 2.4
      expect(computeStrain(light), closeTo(2.4, 0.01));
    });
  });

  group('computeRecovery', () {
    test('returns 1.0 when no fatigue ever recorded', () {
      final list = [makeSession(id: 1, startedAt: now)];
      expect(computeRecovery(list, now: now), 1.0);
    });

    test('returns 0.0 when fatigue happened today', () {
      final list = [makeSession(id: 1, startedAt: now, fatigue: true)];
      expect(computeRecovery(list, now: now), 0.0);
    });

    test('clamps to 1.0 after >7 days', () {
      final list = [
        makeSession(
          id: 1,
          startedAt: now.subtract(const Duration(days: 14)),
          fatigue: true,
        ),
      ];
      expect(computeRecovery(list, now: now), 1.0);
    });

    test('linearly scales between 0 and 7 days', () {
      final list = [
        makeSession(
          id: 1,
          // exactly 3.5 days ago → halfway
          startedAt: now.subtract(const Duration(days: 3, hours: 12)),
          fatigue: true,
        ),
      ];
      expect(computeRecovery(list, now: now), closeTo(0.5, 0.02));
    });
  });

  group('computeOutput', () {
    test('returns 0.0 on empty list', () {
      expect(computeOutput(const []), 0.0);
    });

    test('averages quality across the window', () {
      final list = [
        makeSession(id: 1, startedAt: now, quality: 0.80),
        makeSession(id: 2, startedAt: now, quality: 0.90),
      ];
      expect(computeOutput(list), closeTo(0.85, 1e-9));
    });

    test('skips null quality rows without crashing', () {
      final list = [
        makeSession(id: 1, startedAt: now, quality: null),
        makeSession(id: 2, startedAt: now, quality: 0.70),
      ];
      expect(computeOutput(list), closeTo(0.70, 1e-9));
    });
  });

  group('computeWeeklyBars', () {
    test('all-zero on a fresh install', () {
      expect(computeWeeklyBars(const [], now: now), <int>[0, 0, 0, 0, 0, 0, 0]);
    });

    test('places today\'s session at the right weekday index', () {
      final list = [makeSession(id: 1, startedAt: now, reps: 30)];
      final bars = computeWeeklyBars(list, now: now);
      // 2026-05-13 is Wednesday (weekday 3), index 2.
      expect(bars[2], 30);
      expect(bars.where((v) => v != 0).length, 1);
    });

    test('ignores sessions outside the current ISO week', () {
      // Sunday 9 days back is firmly in the prior week.
      final list = [
        makeSession(
          id: 1,
          startedAt: now.subtract(const Duration(days: 9)),
          reps: 50,
        ),
      ];
      expect(computeWeeklyBars(list, now: now), <int>[0, 0, 0, 0, 0, 0, 0]);
    });

    test('sums multiple same-day sessions into one bar', () {
      final list = [
        makeSession(id: 1, startedAt: now, reps: 10),
        makeSession(
          id: 2,
          startedAt: now.add(const Duration(hours: 2)),
          reps: 15,
        ),
      ];
      final bars = computeWeeklyBars(list, now: now);
      expect(bars[2], 25);
    });
  });

  group('computeTotalHours / countDistinctExercises', () {
    test('total hours sums durations to fractional hours', () {
      final list = [
        makeSession(
          id: 1,
          startedAt: now,
          duration: const Duration(minutes: 30),
        ),
        makeSession(
          id: 2,
          startedAt: now,
          duration: const Duration(minutes: 90),
        ),
      ];
      expect(computeTotalHours(list), closeTo(2.0, 1e-9));
    });

    test('distinct exercises only counts unique types', () {
      final list = [
        makeSession(id: 1, startedAt: now, exercise: ExerciseType.squat),
        makeSession(id: 2, startedAt: now, exercise: ExerciseType.squat),
        makeSession(
          id: 3,
          startedAt: now,
          exercise: ExerciseType.bicepsCurlSide,
        ),
      ];
      expect(countDistinctExercises(list), 2);
    });
  });

  group('computeDashboardMetrics (one-pass entry point)', () {
    test('empty input produces fully zero/safe metrics', () {
      final m = computeDashboardMetrics(const [], now: now);
      expect(m.strain, 0.0);
      expect(m.recovery, 1.0);
      expect(m.output, 0.0);
      expect(m.totalSessions, 0);
      expect(m.totalHours, 0.0);
      expect(m.personalRecords, 0);
      expect(m.weeklyRepCount, 0);
      expect(m.weeklyBars.length, 7);
    });
  });
}
