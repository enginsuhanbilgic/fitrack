import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '_test_db.dart';

/// Build a curl completion event with N reps. Angles/qualities deterministic
/// so round-trip assertions can check exact values.
WorkoutCompletedEvent buildCurlEvent({
  int reps = 3,
  Set<FormError> errors = const {},
  bool fatigue = false,
  bool asymmetry = false,
  CurlCameraView detectedView = CurlCameraView.front,
}) {
  final records = List<CurlRepRecord>.generate(
    reps,
    (i) => CurlRepRecord(
      repIndex: i + 1,
      side: i.isEven ? ProfileSide.left : ProfileSide.right,
      view: detectedView,
      minAngle: 50.0 + i,
      maxAngle: 160.0 + i,
      source: ThresholdSource.calibrated,
      bucketUpdated: true,
      rejectedOutlier: false,
    ),
  );
  final qualities = List<double>.generate(reps, (i) => 0.80 + 0.01 * i);
  return WorkoutCompletedEvent(
    exercise: ExerciseType.bicepsCurl,
    totalReps: reps,
    totalSets: 1,
    sessionDuration: const Duration(seconds: 45),
    averageQuality: qualities.reduce((a, b) => a + b) / qualities.length,
    detectedView: detectedView,
    repQualities: qualities,
    fatigueDetected: fatigue,
    asymmetryDetected: asymmetry,
    eccentricTooFastCount: 0,
    errorsTriggered: errors,
    curlRepRecords: records,
    curlBucketSummaries: const [],
  );
}

WorkoutCompletedEvent buildSquatEvent({int reps = 4}) {
  final qualities = List<double>.generate(reps, (i) => 0.70 + 0.02 * i);
  return WorkoutCompletedEvent(
    exercise: ExerciseType.squat,
    totalReps: reps,
    totalSets: 1,
    sessionDuration: const Duration(seconds: 60),
    averageQuality: qualities.reduce((a, b) => a + b) / qualities.length,
    detectedView: CurlCameraView.unknown,
    repQualities: qualities,
    fatigueDetected: false,
    asymmetryDetected: false,
    eccentricTooFastCount: 0,
    errorsTriggered: const {FormError.squatDepth},
    curlRepRecords: const [],
    curlBucketSummaries: const [],
  );
}

void main() {
  initSqfliteFfi();

  group('SqliteSessionRepository.insertCompletedSession', () {
    late Database db;
    late SqliteSessionRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteSessionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'writes one sessions row + N reps + M form_errors atomically',
      () async {
        final event = buildCurlEvent(
          reps: 3,
          errors: {FormError.torsoSwing, FormError.elbowDrift},
        );
        final id = await repo.insertCompletedSession(
          event,
          startedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
        );
        expect(id, 1);

        final sessions = await db.query('sessions');
        expect(sessions, hasLength(1));
        expect(sessions.first['exercise'], 'bicepsCurl');
        expect(sessions.first['started_at'], 1_700_000_000_000);
        expect(sessions.first['total_reps'], 3);

        final reps = await db.query('reps', orderBy: 'rep_index ASC');
        expect(reps, hasLength(3));
        expect(reps.first['side'], 'left');
        expect(reps.first['view'], 'front');
        expect(reps.first['threshold_source'], 'calibrated');
        expect(reps.first['bucket_updated'], 1);
        expect(reps.first['rejected_outlier'], 0);
        expect(reps.first['concentric_ms'], isNull); // PR4 populates

        final formErrors = await db.query('form_errors');
        expect(formErrors, hasLength(2));
        final names = formErrors.map((r) => r['error']).toSet();
        expect(names, {'torsoSwing', 'elbowDrift'});
      },
    );

    test('enum values serialize as .name, not .index', () async {
      final event = buildCurlEvent(reps: 1);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());
      final reps = await db.query('reps');
      // Must be strings, not integers.
      expect(reps.first['side'], isA<String>());
      expect(reps.first['view'], isA<String>());
      expect(reps.first['threshold_source'], isA<String>());
    });

    test('booleans map to 0/1 round-trip', () async {
      final event = buildCurlEvent(reps: 1, fatigue: true, asymmetry: true);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());
      final session = (await db.query('sessions')).first;
      expect(session['fatigue_detected'], 1);
      expect(session['asymmetry_detected'], 1);
    });

    test('squat session leaves curl-only columns NULL', () async {
      final event = buildSquatEvent(reps: 4);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());

      final session = (await db.query('sessions')).first;
      expect(session['detected_view'], isNull); // CurlCameraView.unknown → NULL
      expect(session['exercise'], 'squat');

      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect(reps, hasLength(4));
      expect(reps.first['side'], isNull);
      expect(reps.first['view'], isNull);
      expect(reps.first['threshold_source'], isNull);
      expect(reps.first['bucket_updated'], isNull);
      expect(reps.first['rejected_outlier'], isNull);
      expect(reps.first['min_angle'], isNull);
      expect(reps.first['max_angle'], isNull);
      // Quality still populated from repQualities.
      expect(reps.first['quality'], closeTo(0.70, 1e-9));
    });

    test(
      'empty event (0 reps, no errors) writes only the sessions row',
      () async {
        final event = WorkoutCompletedEvent(
          exercise: ExerciseType.bicepsCurl,
          totalReps: 0,
          totalSets: 1,
          sessionDuration: Duration.zero,
          averageQuality: null,
          detectedView: CurlCameraView.unknown,
          repQualities: const [],
          fatigueDetected: false,
          asymmetryDetected: false,
          eccentricTooFastCount: 0,
          errorsTriggered: const {},
          curlRepRecords: const [],
          curlBucketSummaries: const [],
        );
        await repo.insertCompletedSession(event, startedAt: DateTime.now());

        expect((await db.query('sessions')), hasLength(1));
        expect((await db.query('reps')), isEmpty);
        expect((await db.query('form_errors')), isEmpty);
      },
    );

    test('quality per rep is aligned by rep_index from repQualities', () async {
      final event = buildCurlEvent(reps: 3);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());
      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect((reps[0]['quality'] as num).toDouble(), closeTo(0.80, 1e-9));
      expect((reps[1]['quality'] as num).toDouble(), closeTo(0.81, 1e-9));
      expect((reps[2]['quality'] as num).toDouble(), closeTo(0.82, 1e-9));
    });
  });

  group('SqliteSessionRepository.listSessions', () {
    late Database db;
    late SqliteSessionRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteSessionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('empty DB returns empty list', () async {
      expect(await repo.listSessions(), isEmpty);
    });

    test('orders by started_at DESC (newest first)', () async {
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 1),
        startedAt: DateTime(2026, 4, 20),
      );
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 2),
        startedAt: DateTime(2026, 4, 25),
      );
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 3),
        startedAt: DateTime(2026, 4, 22),
      );
      final list = await repo.listSessions();
      expect(list.map((s) => s.totalReps).toList(), [2, 3, 1]);
    });

    test('exercise filter narrows results', () async {
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 1),
        startedAt: DateTime.now(),
      );
      await repo.insertCompletedSession(
        buildSquatEvent(reps: 5),
        startedAt: DateTime.now(),
      );
      final curls = await repo.listSessions(exercise: ExerciseType.bicepsCurl);
      final squats = await repo.listSessions(exercise: ExerciseType.squat);
      expect(curls, hasLength(1));
      expect(curls.first.exercise, ExerciseType.bicepsCurl);
      expect(squats, hasLength(1));
      expect(squats.first.exercise, ExerciseType.squat);
    });

    test('limit + offset paginate', () async {
      for (var i = 0; i < 5; i++) {
        await repo.insertCompletedSession(
          buildCurlEvent(reps: i + 1),
          startedAt: DateTime(2026, 4, 20 + i),
        );
      }
      final page1 = await repo.listSessions(limit: 2, offset: 0);
      final page2 = await repo.listSessions(limit: 2, offset: 2);
      expect(page1, hasLength(2));
      expect(page2, hasLength(2));
      expect(page1.first.totalReps, 5); // newest
    });

    test('detectedView is null for squat and unknown curl', () async {
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 1, detectedView: CurlCameraView.unknown),
        startedAt: DateTime.now(),
      );
      final list = await repo.listSessions();
      expect(list.first.detectedView, isNull);
    });
  });

  group('SqliteSessionRepository.getSession', () {
    late Database db;
    late SqliteSessionRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteSessionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('returns null for missing id', () async {
      expect(await repo.getSession(999), isNull);
    });

    test('loads session + all reps + aggregated form errors', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 2, errors: {FormError.torsoSwing}),
        startedAt: DateTime.now(),
      );
      final detail = (await repo.getSession(id))!;
      expect(detail.summary.totalReps, 2);
      expect(detail.reps, hasLength(2));
      expect(detail.reps.first.repIndex, 1);
      expect(detail.reps.first.side, ProfileSide.left);
      expect(detail.formErrors[FormError.torsoSwing], 1);
    });

    test('reps are ordered by rep_index ASC', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 3),
        startedAt: DateTime.now(),
      );
      final detail = (await repo.getSession(id))!;
      expect(detail.reps.map((r) => r.repIndex).toList(), [1, 2, 3]);
    });
  });

  group('SqliteSessionRepository.deleteSession', () {
    late Database db;
    late SqliteSessionRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteSessionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('removes session row', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 1),
        startedAt: DateTime.now(),
      );
      await repo.deleteSession(id);
      expect(await repo.getSession(id), isNull);
    });

    test('CASCADE: deleting session drops reps + form_errors', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 3, errors: {FormError.torsoSwing}),
        startedAt: DateTime.now(),
      );
      expect((await db.query('reps')), hasLength(3));
      expect((await db.query('form_errors')), hasLength(1));

      await repo.deleteSession(id);

      expect((await db.query('reps')), isEmpty);
      expect((await db.query('form_errors')), isEmpty);
    });
  });

  group('SqliteSessionRepository.recentConcentricDurations', () {
    late Database db;
    late SqliteSessionRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteSessionRepository(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'returns empty list in PR2 (column exists but not populated)',
      () async {
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 3),
          startedAt: DateTime.now(),
        );
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurl,
          window: const Duration(days: 30),
        );
        expect(result, isEmpty);
      },
    );
  });

  group('InMemorySessionRepository', () {
    late InMemorySessionRepository repo;

    setUp(() {
      repo = InMemorySessionRepository();
    });

    test('round-trip: insert then listSessions + getSession', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 2, errors: {FormError.elbowDrift}),
        startedAt: DateTime(2026, 4, 25),
      );
      final list = await repo.listSessions();
      expect(list, hasLength(1));
      expect(list.first.id, id);
      final detail = (await repo.getSession(id))!;
      expect(detail.reps, hasLength(2));
      expect(detail.formErrors[FormError.elbowDrift], 1);
    });

    test('deleteSession removes it', () async {
      final id = await repo.insertCompletedSession(
        buildCurlEvent(reps: 1),
        startedAt: DateTime.now(),
      );
      await repo.deleteSession(id);
      expect(await repo.getSession(id), isNull);
      expect(await repo.listSessions(), isEmpty);
    });

    test(
      'listSessions newest-first + exercise filter matches Sqlite impl',
      () async {
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 1),
          startedAt: DateTime(2026, 4, 20),
        );
        await repo.insertCompletedSession(
          buildSquatEvent(reps: 5),
          startedAt: DateTime(2026, 4, 25),
        );
        final all = await repo.listSessions();
        expect(all.first.exercise, ExerciseType.squat); // newer
        final curls = await repo.listSessions(
          exercise: ExerciseType.bicepsCurl,
        );
        expect(curls, hasLength(1));
      },
    );

    test(
      'recentConcentricDurations returns empty (parity with Sqlite stub)',
      () async {
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurl,
          window: const Duration(days: 30),
        );
        expect(result, isEmpty);
      },
    );
  });
}
