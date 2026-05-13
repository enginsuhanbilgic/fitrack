/// Pure-Dart unit tests for `DemoSeed.build()`. Verifies blueprint
/// invariants: session count, date windowing, per-rep angle plausibility,
/// ROM-profile calibration sample counts, and determinism across runs at
/// the same `now`.
library;

import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/demo/demo_seed.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DemoSeed.build()', () {
    test('returns exactly 14 sessions', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      expect(blueprint.sessions, hasLength(14));
    });

    test('every session starts within the last 22 days', () {
      final now = DateTime(2026, 5, 13);
      final blueprint = DemoSeed.build(now: now);
      for (final s in blueprint.sessions) {
        final ts = s.sessionRow['started_at']! as int;
        final startedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        final daysAgo = now.difference(startedAt).inDays;
        expect(daysAgo, inInclusiveRange(0, 22));
      }
    });

    test('every session row is tagged is_demo=1', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      for (final s in blueprint.sessions) {
        expect(s.sessionRow['is_demo'], 1);
      }
    });

    test('every rep has min_angle < max_angle and concentric_ms populated', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      for (final session in blueprint.sessions) {
        for (final r in session.repRows) {
          final minA = r['min_angle']! as double;
          final maxA = r['max_angle']! as double;
          expect(minA < maxA, isTrue, reason: 'min_angle must be < max_angle');
          final cms = r['concentric_ms']! as int;
          expect(cms, inInclusiveRange(1200, 2000));
        }
      }
    });

    test(
      'blueprint does NOT carry ROM profiles (operator decision: demo uses cold-start defaults)',
      () {
        final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
        // The DemoBlueprint class intentionally exposes only `userProfile`
        // and `sessions`. The pre-followup fields (`curlProfile`,
        // `squatProfile`, `pushUpProfile`) are gone. Recorded per-rep
        // angles still flow through `sessions[i].repRows` — those are
        // session data, not profile data, and remain part of the seed.
        expect(blueprint.userProfile, isNotNull);
        expect(blueprint.sessions, hasLength(14));
      },
    );

    test('determinism: two builds at same now produce identical row maps', () {
      final now = DateTime(2026, 5, 13);
      final a = DemoSeed.build(now: now);
      final b = DemoSeed.build(now: now);
      expect(a.sessions.length, b.sessions.length);
      for (var i = 0; i < a.sessions.length; i++) {
        expect(a.sessions[i].sessionRow, b.sessions[i].sessionRow);
        expect(a.sessions[i].repRows, b.sessions[i].repRows);
        expect(a.sessions[i].formErrorRows, b.sessions[i].formErrorRows);
      }
    });

    test('asymmetry flag is never set (Gap 27)', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      for (final s in blueprint.sessions) {
        expect(s.sessionRow['asymmetry_detected'], 0);
      }
    });

    test('Day -15 curl session sets eccentric_too_fast_count=2 (Gap 26)', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      final fatigued = blueprint.sessions.firstWhere(
        (s) => s.sessionRow['fatigue_detected'] == 1,
      );
      expect(fatigued.sessionRow['eccentric_too_fast_count'], 2);
      expect(fatigued.sessionRow['exercise'], ExerciseType.bicepsCurlSide.name);
    });

    test('curl rep rows carry side-view biceps metrics', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      final curlSession = blueprint.sessions.firstWhere(
        (s) =>
            (s.sessionRow['exercise']! as String) ==
            ExerciseType.bicepsCurlSide.name,
      );
      final rep = curlSession.repRows.first;
      expect(rep['biceps_lean_deg'], isA<double>());
      expect(rep['biceps_shoulder_drift_ratio'], isA<double>());
      expect(rep['biceps_shrug_ratio'], isA<double>());
      expect(rep['biceps_elbow_rise_ratio'], isA<double>());
      expect(rep['side'], isNotNull);
      expect(rep['view'], isNotNull);
      expect(rep['threshold_source'], ThresholdSource.calibrated.name);
    });

    test('squat rep rows carry squat metrics + min/max knee angles', () {
      final blueprint = DemoSeed.build(now: DateTime(2026, 5, 13));
      final squatSession = blueprint.sessions.firstWhere(
        (s) => (s.sessionRow['exercise']! as String) == ExerciseType.squat.name,
      );
      final rep = squatSession.repRows.first;
      expect(rep['squat_lean_deg'], isA<double>());
      expect(rep['squat_min_knee_angle'], isA<double>());
      expect(rep['squat_max_knee_angle'], isA<double>());
      expect(rep['squat_variant'], SquatVariant.bodyweight.name);
    });
  });
}
