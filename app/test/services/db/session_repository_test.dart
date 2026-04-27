import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/schema.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

/// Build a curl completion event with N reps. Angles/qualities deterministic
/// so round-trip assertions can check exact values.
///
/// `exercise` defaults to [ExerciseType.bicepsCurlFront]; pass
/// `bicepsCurlSide` to exercise the schema-v5 side-metric write path. The
/// default `withSideMetrics: false` keeps the front-curl tests' shape
/// untouched. When `withSideMetrics: true`, deterministic per-rep maxes are
/// generated with a small per-rep increment so the index alignment is
/// visible in SQL row dumps.
WorkoutCompletedEvent buildCurlEvent({
  int reps = 3,
  Set<FormError> errors = const {},
  bool fatigue = false,
  bool asymmetry = false,
  CurlCameraView detectedView = CurlCameraView.front,
  ExerciseType exercise = ExerciseType.bicepsCurlFront,
  bool withSideMetrics = false,
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
  final sideMetrics = withSideMetrics
      ? List<BicepsSideRepMetrics>.generate(
          reps,
          (i) => BicepsSideRepMetrics(
            repIndex: i + 1,
            leanDeg: 5.0 + i,
            shoulderDriftRatio: 0.10 + 0.01 * i,
            elbowDriftRatio: 0.20 + 0.01 * i,
            backLeanDeg: 2.0 + 0.5 * i,
            // Alternate sign per rep so round-trip pins both directions.
            elbowDriftSigned: i.isEven ? 0.20 + 0.01 * i : -(0.20 + 0.01 * i),
          ),
        )
      : const <BicepsSideRepMetrics>[];
  return WorkoutCompletedEvent(
    exercise: exercise,
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
    bicepsSideRepMetrics: sideMetrics,
  );
}

WorkoutCompletedEvent buildSquatEvent({
  int reps = 4,
  SquatVariant variant = SquatVariant.bodyweight,
  bool longFemurLifter = false,
  bool withRepMetrics = false,
}) {
  final qualities = List<double>.generate(reps, (i) => 0.70 + 0.02 * i);
  // Deterministic per-rep metrics so round-trip assertions can pin exact
  // values. Each rep's lean/knee-shift/heel-lift increments slightly so the
  // index alignment is visible in the SQL row dump.
  final metrics = withRepMetrics
      ? List<SquatRepMetrics>.generate(
          reps,
          (i) => SquatRepMetrics(
            repIndex: i + 1,
            quality: qualities[i],
            leanDeg: 30.0 + i,
            kneeShiftRatio: 0.10 + 0.01 * i,
            heelLiftRatio: 0.01 + 0.005 * i,
          ),
        )
      : const <SquatRepMetrics>[];
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
    squatVariant: variant,
    squatLongFemurLifter: longFemurLifter,
    squatRepMetrics: metrics,
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
        expect(sessions.first['exercise'], 'bicepsCurlFront');
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
          exercise: ExerciseType.bicepsCurlFront,
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
      final curls = await repo.listSessions(
        exercise: ExerciseType.bicepsCurlFront,
      );
      final squats = await repo.listSessions(exercise: ExerciseType.squat);
      expect(curls, hasLength(1));
      expect(curls.first.exercise, ExerciseType.bicepsCurlFront);
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
      'empty when concentricDurations not passed (pre-WP5.4 behavior)',
      () async {
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 3),
          startedAt: DateTime.now(),
        );
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurlFront,
          window: const Duration(days: 30),
        );
        expect(result, isEmpty);
      },
    );

    test(
      'returns durations within the window, newest-first, filtered by exercise',
      () async {
        // Old curl session: 35 days ago, 2 reps — OUT of 30-day window.
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 2),
          startedAt: DateTime.now().subtract(const Duration(days: 35)),
          concentricDurations: const [
            Duration(milliseconds: 999),
            Duration(milliseconds: 888),
          ],
        );
        // Recent curl session: 5 days ago, 3 reps.
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 3),
          startedAt: DateTime.now().subtract(const Duration(days: 5)),
          concentricDurations: const [
            Duration(milliseconds: 100),
            Duration(milliseconds: 110),
            Duration(milliseconds: 120),
          ],
        );
        // Squat session: 2 days ago — must NOT bleed into curl results.
        await repo.insertCompletedSession(
          buildSquatEvent(reps: 2),
          startedAt: DateTime.now().subtract(const Duration(days: 2)),
          concentricDurations: const [
            Duration(milliseconds: 500),
            Duration(milliseconds: 600),
          ],
        );

        final curl = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurlFront,
          window: const Duration(days: 30),
        );
        expect(curl.map((d) => d.inMilliseconds).toList(), [100, 110, 120]);

        final squat = await repo.recentConcentricDurations(
          exercise: ExerciseType.squat,
          window: const Duration(days: 30),
        );
        expect(squat.map((d) => d.inMilliseconds).toList(), [500, 600]);
      },
    );

    test(
      'skips rows where concentric_ms is NULL (mixed pre/post-WP5.4 data)',
      () async {
        // Older session with no durations written.
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 2),
          startedAt: DateTime.now().subtract(const Duration(days: 3)),
        );
        // Recent session WITH durations.
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 2),
          startedAt: DateTime.now().subtract(const Duration(days: 1)),
          concentricDurations: const [
            Duration(milliseconds: 250),
            Duration(milliseconds: 260),
          ],
        );
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurlFront,
          window: const Duration(days: 30),
        );
        expect(result.map((d) => d.inMilliseconds).toList(), [250, 260]);
      },
    );

    test('limitReps caps the returned list', () async {
      await repo.insertCompletedSession(
        buildCurlEvent(reps: 5),
        startedAt: DateTime.now(),
        concentricDurations: const [
          Duration(milliseconds: 100),
          Duration(milliseconds: 200),
          Duration(milliseconds: 300),
          Duration(milliseconds: 400),
          Duration(milliseconds: 500),
        ],
      );
      final result = await repo.recentConcentricDurations(
        exercise: ExerciseType.bicepsCurlFront,
        window: const Duration(days: 30),
        limitReps: 2,
      );
      expect(result, hasLength(2));
    });
  });

  group(
    'SqliteSessionRepository.insertCompletedSession — WP5.4 concentric_ms',
    () {
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
        'persists per-rep concentric_ms in reps table, aligned by rep_index',
        () async {
          await repo.insertCompletedSession(
            buildCurlEvent(reps: 3),
            startedAt: DateTime.now(),
            concentricDurations: const [
              Duration(milliseconds: 420),
              null, // rep 2 missed the peak-reached timing
              Duration(milliseconds: 380),
            ],
          );
          final rows = await db.query('reps', orderBy: 'rep_index ASC');
          expect(rows, hasLength(3));
          expect(rows[0]['concentric_ms'], 420);
          expect(rows[1]['concentric_ms'], isNull);
          expect(rows[2]['concentric_ms'], 380);
        },
      );

      test(
        'missing entries (list shorter than reps) write NULL, no crash',
        () async {
          await repo.insertCompletedSession(
            buildCurlEvent(reps: 4),
            startedAt: DateTime.now(),
            concentricDurations: const [
              Duration(milliseconds: 100),
              Duration(milliseconds: 120),
            ],
          );
          final rows = await db.query('reps', orderBy: 'rep_index ASC');
          expect(rows, hasLength(4));
          expect(rows[0]['concentric_ms'], 100);
          expect(rows[1]['concentric_ms'], 120);
          expect(rows[2]['concentric_ms'], isNull);
          expect(rows[3]['concentric_ms'], isNull);
        },
      );

      test(
        'non-curl session persists concentric_ms on repQualities-only path',
        () async {
          await repo.insertCompletedSession(
            buildSquatEvent(reps: 3),
            startedAt: DateTime.now(),
            concentricDurations: const [
              Duration(milliseconds: 700),
              Duration(milliseconds: 720),
              Duration(milliseconds: 740),
            ],
          );
          final rows = await db.query('reps', orderBy: 'rep_index ASC');
          expect(rows, hasLength(3));
          expect(rows[0]['concentric_ms'], 700);
          expect(rows[2]['concentric_ms'], 740);
        },
      );
    },
  );

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
          exercise: ExerciseType.bicepsCurlFront,
        );
        expect(curls, hasLength(1));
      },
    );

    test(
      'recentConcentricDurations on empty repo returns empty list',
      () async {
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurlFront,
          window: const Duration(days: 30),
        );
        expect(result, isEmpty);
      },
    );

    test(
      'recentConcentricDurations returns stored durations filtered by exercise + window',
      () async {
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 2),
          startedAt: DateTime.now().subtract(const Duration(days: 3)),
          concentricDurations: const [
            Duration(milliseconds: 150),
            Duration(milliseconds: 160),
          ],
        );
        await repo.insertCompletedSession(
          buildCurlEvent(reps: 1),
          startedAt: DateTime.now().subtract(const Duration(days: 60)),
          concentricDurations: const [Duration(milliseconds: 999)],
        );
        final result = await repo.recentConcentricDurations(
          exercise: ExerciseType.bicepsCurlFront,
          window: const Duration(days: 30),
        );
        expect(result.map((d) => d.inMilliseconds).toList(), [150, 160]);
      },
    );
  });

  group('Squat per-rep metrics — schema v3 round-trip', () {
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
      'squat session writes lean/knee-shift/heel-lift/variant per rep',
      () async {
        final event = buildSquatEvent(
          reps: 3,
          variant: SquatVariant.highBarBackSquat,
          withRepMetrics: true,
        );
        await repo.insertCompletedSession(event, startedAt: DateTime.now());

        final reps = await db.query('reps', orderBy: 'rep_index ASC');
        expect(reps, hasLength(3));
        // Rep 1: leanDeg=30, kneeShift=0.10, heelLift=0.01
        expect(
          (reps[0]['squat_lean_deg'] as num).toDouble(),
          closeTo(30.0, 1e-9),
        );
        expect(
          (reps[0]['squat_knee_shift_ratio'] as num).toDouble(),
          closeTo(0.10, 1e-9),
        );
        expect(
          (reps[0]['squat_heel_lift_ratio'] as num).toDouble(),
          closeTo(0.01, 1e-9),
        );
        expect(reps[0]['squat_variant'], 'highBarBackSquat');
        // Rep 3 — index alignment: leanDeg=32, kneeShift=0.12, heelLift=0.02
        expect(
          (reps[2]['squat_lean_deg'] as num).toDouble(),
          closeTo(32.0, 1e-9),
        );
        expect(
          (reps[2]['squat_knee_shift_ratio'] as num).toDouble(),
          closeTo(0.12, 1e-9),
        );
      },
    );

    test('squat session WITHOUT per-rep metrics writes NULL columns', () async {
      // Pre-rebuild squat sessions, or live sessions where the analyzer
      // returned null for every metric (no landmark coverage).
      final event = buildSquatEvent(reps: 2);
      expect(event.squatRepMetrics, isEmpty);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());

      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect(reps, hasLength(2));
      for (final r in reps) {
        expect(r['squat_lean_deg'], isNull);
        expect(r['squat_knee_shift_ratio'], isNull);
        expect(r['squat_heel_lift_ratio'], isNull);
        expect(r['squat_variant'], isNull);
      }
    });

    test('curl session leaves all 4 squat columns NULL', () async {
      final event = buildCurlEvent(reps: 2);
      await repo.insertCompletedSession(event, startedAt: DateTime.now());

      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect(reps, hasLength(2));
      for (final r in reps) {
        expect(r['squat_lean_deg'], isNull);
        expect(r['squat_knee_shift_ratio'], isNull);
        expect(r['squat_heel_lift_ratio'], isNull);
        expect(r['squat_variant'], isNull);
      }
    });

    test('getSession reconstructs squat metrics on RepRow', () async {
      final event = buildSquatEvent(
        reps: 2,
        variant: SquatVariant.bodyweight,
        withRepMetrics: true,
      );
      final id = await repo.insertCompletedSession(
        event,
        startedAt: DateTime.now(),
      );

      final detail = await repo.getSession(id);
      expect(detail, isNotNull);
      expect(detail!.reps, hasLength(2));
      expect(detail.reps[0].squatLeanDeg, closeTo(30.0, 1e-9));
      expect(detail.reps[0].squatKneeShiftRatio, closeTo(0.10, 1e-9));
      expect(detail.reps[0].squatHeelLiftRatio, closeTo(0.01, 1e-9));
      expect(detail.reps[0].squatVariant, SquatVariant.bodyweight);
    });

    test('unknown squat_variant string in DB falls back to NULL', () async {
      // Simulate a future build inserting `frontSquat` (not in current enum).
      // The read path must not throw — same defense as
      // SqlitePreferencesRepository.getSquatVariant.
      await db.insert('sessions', <String, Object?>{
        'exercise': 'squat',
        'started_at': DateTime.now().millisecondsSinceEpoch,
        'duration_ms': 0,
        'total_reps': 1,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
      });
      final sessionId =
          (await db.query('sessions', orderBy: 'id DESC', limit: 1)).first['id']
              as int;
      await db.insert('reps', <String, Object?>{
        'session_id': sessionId,
        'rep_index': 1,
        'squat_variant': 'overheadSquat',
      });

      final detail = await repo.getSession(sessionId);
      expect(detail, isNotNull);
      expect(detail!.reps.first.squatVariant, isNull);
    });
  });

  group('Schema v2 → v3 migration', () {
    test(
      'onUpgrade adds the 4 squat columns to reps without losing data',
      () async {
        // Open a v2 DB by skipping the v3 ALTERs in onCreate, populate one
        // row, then run onUpgrade(2, 3) and assert the row survives.
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 2,
            onConfigure: onConfigure,
            onCreate: (db, _) async {
              await db.execute(ddlProfiles);
              await db.execute(ddlSessions);
              await db.execute(ddlReps);
              await db.execute(ddlFormErrors);
              await db.execute(ddlFrameTelemetry);
              await db.execute(ddlPreferences);
              // Replicate the v2 onCreate state exactly.
              await db.execute(
                'ALTER TABLE reps ADD COLUMN dtw_similarity REAL',
              );
            },
          ),
        );
        // Insert a row that should survive the migration intact.
        await db.insert('sessions', <String, Object?>{
          'exercise': 'squat',
          'started_at': 1_700_000_000_000,
          'duration_ms': 60000,
          'total_reps': 1,
          'total_sets': 1,
          'fatigue_detected': 0,
          'asymmetry_detected': 0,
          'eccentric_too_fast_count': 0,
        });
        final sid = (await db.query('sessions', limit: 1)).first['id'] as int;
        await db.insert('reps', <String, Object?>{
          'session_id': sid,
          'rep_index': 1,
          'quality': 0.85,
        });

        await onUpgrade(db, 2, kDbSchemaVersion);

        final cols = (await db.rawQuery(
          'PRAGMA table_info(reps)',
        )).map((r) => r['name'] as String).toList();
        expect(
          cols,
          containsAll([
            'squat_lean_deg',
            'squat_knee_shift_ratio',
            'squat_heel_lift_ratio',
            'squat_variant',
          ]),
        );

        // Pre-existing row survives with NULL in the new columns.
        final reps = await db.query('reps');
        expect(reps, hasLength(1));
        expect((reps.first['quality'] as num).toDouble(), closeTo(0.85, 1e-9));
        expect(reps.first['squat_lean_deg'], isNull);
        expect(reps.first['squat_variant'], isNull);

        await db.close();
      },
    );

    test('fresh v3 install has all 4 squat columns', () async {
      final db = await openTestDb();
      final cols = (await db.rawQuery(
        'PRAGMA table_info(reps)',
      )).map((r) => r['name'] as String).toList();
      expect(
        cols,
        containsAll([
          'squat_lean_deg',
          'squat_knee_shift_ratio',
          'squat_heel_lift_ratio',
          'squat_variant',
        ]),
      );
      await db.close();
    });
  });

  group('Schema v3 → v4 migration', () {
    test('onUpgrade rewrites bicepsCurl rows to bicepsCurlFront', () async {
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 3,
          onConfigure: onConfigure,
          onCreate: (db, _) async {
            await db.execute(ddlProfiles);
            await db.execute(ddlSessions);
            await db.execute(ddlReps);
            await db.execute(ddlFormErrors);
            await db.execute(ddlFrameTelemetry);
            await db.execute(ddlPreferences);
            await db.execute('ALTER TABLE reps ADD COLUMN dtw_similarity REAL');
            await db.execute('ALTER TABLE reps ADD COLUMN squat_lean_deg REAL');
            await db.execute(
              'ALTER TABLE reps ADD COLUMN squat_knee_shift_ratio REAL',
            );
            await db.execute(
              'ALTER TABLE reps ADD COLUMN squat_heel_lift_ratio REAL',
            );
            await db.execute('ALTER TABLE reps ADD COLUMN squat_variant TEXT');
          },
        ),
      );

      // Insert a legacy 'bicepsCurl' row.
      await db.insert('sessions', <String, Object?>{
        'exercise': 'bicepsCurl',
        'started_at': 1_700_000_000_000,
        'duration_ms': 60000,
        'total_reps': 5,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
      });
      // Insert a non-curl row that must not be touched.
      await db.insert('sessions', <String, Object?>{
        'exercise': 'squat',
        'started_at': 1_700_000_001_000,
        'duration_ms': 60000,
        'total_reps': 3,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
      });

      await onUpgrade(db, 3, kDbSchemaVersion);

      final sessions = await db.query('sessions', orderBy: 'started_at ASC');
      expect(sessions, hasLength(2));
      expect(sessions[0]['exercise'], 'bicepsCurlFront');
      expect(sessions[1]['exercise'], 'squat');

      await db.close();
    });

    test(
      'SqliteSessionRepository reads legacy bicepsCurl row without throwing',
      () async {
        // Simulate a row that somehow escaped the v4 migration. The deprecated
        // bicepsCurl enum value is retained precisely for this case — byName
        // resolves it cleanly and returns ExerciseType.bicepsCurl.
        // The _parseExerciseType try/catch is a safety net for truly unknown
        // strings (e.g. future values rolled back); bicepsCurl is not unknown.
        final db = await openTestDb();

        final repo = SqliteSessionRepository(db);
        final event = WorkoutCompletedEvent(
          exercise: ExerciseType.bicepsCurlFront,
          totalReps: 1,
          totalSets: 1,
          sessionDuration: const Duration(minutes: 1),
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
        await repo.insertCompletedSession(
          event,
          startedAt: DateTime.fromMillisecondsSinceEpoch(1_700_000_000_000),
        );

        // Patch the row to simulate a pre-migration legacy state.
        await db.rawUpdate("UPDATE sessions SET exercise = 'bicepsCurl'");

        final sessions = await repo.listSessions();
        expect(sessions, hasLength(1));
        // byName('bicepsCurl') succeeds — the deprecated value is retained.
        // ignore: deprecated_member_use
        expect(sessions.first.exercise, ExerciseType.bicepsCurl);

        await db.close();
      },
    );
  });

  group('Biceps side-view per-rep metrics — schema v5 round-trip', () {
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
      'bicepsCurlSide session writes lean / shoulder / elbow / back-lean per rep',
      () async {
        final event = buildCurlEvent(
          reps: 3,
          exercise: ExerciseType.bicepsCurlSide,
          detectedView: CurlCameraView.sideLeft,
          withSideMetrics: true,
        );
        await repo.insertCompletedSession(event, startedAt: DateTime.now());

        final reps = await db.query('reps', orderBy: 'rep_index ASC');
        expect(reps, hasLength(3));
        // Rep 1: leanDeg=5.0, shoulder=0.10, elbow=0.20, backLean=2.0
        expect(
          (reps[0]['biceps_lean_deg'] as num).toDouble(),
          closeTo(5.0, 1e-9),
        );
        expect(
          (reps[0]['biceps_shoulder_drift_ratio'] as num).toDouble(),
          closeTo(0.10, 1e-9),
        );
        expect(
          (reps[0]['biceps_elbow_drift_ratio'] as num).toDouble(),
          closeTo(0.20, 1e-9),
        );
        expect(
          (reps[0]['biceps_back_lean_deg'] as num).toDouble(),
          closeTo(2.0, 1e-9),
        );
        // Rep 3 — index alignment: leanDeg=7.0, elbow=0.22.
        expect(
          (reps[2]['biceps_lean_deg'] as num).toDouble(),
          closeTo(7.0, 1e-9),
        );
        expect(
          (reps[2]['biceps_elbow_drift_ratio'] as num).toDouble(),
          closeTo(0.22, 1e-9),
        );
        // Signed elbow drift: rep 1 (i=0, even) is positive, rep 2 (i=1)
        // is negative. The retune pipeline relies on this sign survival.
        expect(
          (reps[0]['biceps_elbow_drift_signed'] as num).toDouble(),
          closeTo(0.20, 1e-9),
        );
        expect(
          (reps[1]['biceps_elbow_drift_signed'] as num).toDouble(),
          closeTo(-0.21, 1e-9),
        );
      },
    );

    test(
      'bicepsCurlSide session WITHOUT per-rep metrics writes NULL columns',
      () async {
        final event = buildCurlEvent(
          reps: 2,
          exercise: ExerciseType.bicepsCurlSide,
          detectedView: CurlCameraView.sideLeft,
        );
        expect(event.bicepsSideRepMetrics, isEmpty);
        await repo.insertCompletedSession(event, startedAt: DateTime.now());

        final reps = await db.query('reps', orderBy: 'rep_index ASC');
        expect(reps, hasLength(2));
        for (final r in reps) {
          expect(r['biceps_lean_deg'], isNull);
          expect(r['biceps_shoulder_drift_ratio'], isNull);
          expect(r['biceps_elbow_drift_ratio'], isNull);
          expect(r['biceps_back_lean_deg'], isNull);
          expect(r['biceps_elbow_drift_signed'], isNull);
        }
      },
    );

    test('bicepsCurlFront session leaves the 5 biceps columns NULL even when '
        'metrics are mistakenly populated', () async {
      // Defense-in-depth: even if a future code path pushed metrics on a
      // front-curl event by mistake, the write path's `isCurlSide` gate
      // must keep them out of the `reps` row.
      final event = buildCurlEvent(
        reps: 2,
        exercise: ExerciseType.bicepsCurlFront,
        detectedView: CurlCameraView.front,
        withSideMetrics: true,
      );
      await repo.insertCompletedSession(event, startedAt: DateTime.now());

      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect(reps, hasLength(2));
      for (final r in reps) {
        expect(r['biceps_lean_deg'], isNull);
        expect(r['biceps_shoulder_drift_ratio'], isNull);
        expect(r['biceps_elbow_drift_ratio'], isNull);
        expect(r['biceps_back_lean_deg'], isNull);
        expect(r['biceps_elbow_drift_signed'], isNull);
      }
    });

    test('squat / push-up rows leave the 5 biceps columns NULL', () async {
      // Squat goes through the non-curl write branch — the biceps columns
      // aren't even passed in the insert map. Read-back must surface
      // NULLs without exception.
      final squatEvent = buildSquatEvent(
        reps: 2,
        variant: SquatVariant.bodyweight,
        withRepMetrics: true,
      );
      await repo.insertCompletedSession(squatEvent, startedAt: DateTime.now());

      final reps = await db.query('reps', orderBy: 'rep_index ASC');
      expect(reps, hasLength(2));
      for (final r in reps) {
        expect(r['biceps_lean_deg'], isNull);
        expect(r['biceps_shoulder_drift_ratio'], isNull);
        expect(r['biceps_elbow_drift_ratio'], isNull);
        expect(r['biceps_back_lean_deg'], isNull);
        expect(r['biceps_elbow_drift_signed'], isNull);
      }
    });

    test(
      'getSession reconstructs biceps side-view metrics on RepRow',
      () async {
        final event = buildCurlEvent(
          reps: 2,
          exercise: ExerciseType.bicepsCurlSide,
          detectedView: CurlCameraView.sideRight,
          withSideMetrics: true,
        );
        final id = await repo.insertCompletedSession(
          event,
          startedAt: DateTime.now(),
        );

        final detail = await repo.getSession(id);
        expect(detail, isNotNull);
        expect(detail!.reps, hasLength(2));
        expect(detail.reps[0].bicepsLeanDeg, closeTo(5.0, 1e-9));
        expect(detail.reps[0].bicepsShoulderDriftRatio, closeTo(0.10, 1e-9));
        expect(detail.reps[0].bicepsElbowDriftRatio, closeTo(0.20, 1e-9));
        expect(detail.reps[0].bicepsBackLeanDeg, closeTo(2.0, 1e-9));
        expect(detail.reps[0].bicepsElbowDriftSigned, closeTo(0.20, 1e-9));
        // Rep 2 (i=1, odd) has the negative sign — proves both directions
        // round-trip through `getSession`.
        expect(detail.reps[1].bicepsElbowDriftSigned, closeTo(-0.21, 1e-9));
      },
    );
  });

  group('Schema v4 → v5 migration', () {
    test(
      'onUpgrade adds the 5 biceps columns to reps without losing data',
      () async {
        // Open a v4 DB (replicates the v4 onCreate state exactly), populate
        // one row, run onUpgrade(4, kDbSchemaVersion), and assert survival.
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 4,
            onConfigure: onConfigure,
            onCreate: (db, _) async {
              await db.execute(ddlProfiles);
              await db.execute(ddlSessions);
              await db.execute(ddlReps);
              await db.execute(ddlFormErrors);
              await db.execute(ddlFrameTelemetry);
              await db.execute(ddlPreferences);
              await db.execute(
                'ALTER TABLE reps ADD COLUMN dtw_similarity REAL',
              );
              await db.execute(
                'ALTER TABLE reps ADD COLUMN squat_lean_deg REAL',
              );
              await db.execute(
                'ALTER TABLE reps ADD COLUMN squat_knee_shift_ratio REAL',
              );
              await db.execute(
                'ALTER TABLE reps ADD COLUMN squat_heel_lift_ratio REAL',
              );
              await db.execute(
                'ALTER TABLE reps ADD COLUMN squat_variant TEXT',
              );
            },
          ),
        );

        // Insert a row that should survive the migration intact.
        await db.insert('sessions', <String, Object?>{
          'exercise': 'bicepsCurlSide',
          'started_at': 1_700_000_000_000,
          'duration_ms': 60000,
          'total_reps': 1,
          'total_sets': 1,
          'fatigue_detected': 0,
          'asymmetry_detected': 0,
          'eccentric_too_fast_count': 0,
        });
        final sid = (await db.query('sessions', limit: 1)).first['id'] as int;
        await db.insert('reps', <String, Object?>{
          'session_id': sid,
          'rep_index': 1,
          'quality': 0.91,
        });

        await onUpgrade(db, 4, kDbSchemaVersion);

        final cols = (await db.rawQuery(
          'PRAGMA table_info(reps)',
        )).map((r) => r['name'] as String).toList();
        expect(
          cols,
          containsAll([
            'biceps_lean_deg',
            'biceps_shoulder_drift_ratio',
            'biceps_elbow_drift_ratio',
            'biceps_back_lean_deg',
            'biceps_elbow_drift_signed',
          ]),
        );

        // Pre-existing row survives with NULL in the new columns.
        final reps = await db.query('reps');
        expect(reps, hasLength(1));
        expect((reps.first['quality'] as num).toDouble(), closeTo(0.91, 1e-9));
        expect(reps.first['biceps_lean_deg'], isNull);
        expect(reps.first['biceps_elbow_drift_ratio'], isNull);
        expect(reps.first['biceps_elbow_drift_signed'], isNull);

        await db.close();
      },
    );

    test('fresh v5 install has all 5 biceps columns', () async {
      final db = await openTestDb();
      final cols = (await db.rawQuery(
        'PRAGMA table_info(reps)',
      )).map((r) => r['name'] as String).toList();
      expect(
        cols,
        containsAll([
          'biceps_lean_deg',
          'biceps_shoulder_drift_ratio',
          'biceps_elbow_drift_ratio',
          'biceps_back_lean_deg',
          'biceps_elbow_drift_signed',
        ]),
      );
      await db.close();
    });
  });
}
