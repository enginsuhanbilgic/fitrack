import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:fitrack/services/db/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('SqlitePreferencesRepository — schema shape', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('preferences table exists in current schema', () async {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='preferences'",
      );
      expect(tables, hasLength(1));
    });

    test(
      'reps table retains dtw_similarity column (always-NULL after DTW removal)',
      () async {
        // The column cannot be dropped without a table rewrite (SQLite limitation);
        // it persists as a nullable field that all post-2026-05-13 writes leave NULL.
        final info = await db.rawQuery('PRAGMA table_info(reps)');
        final colNames = info.map((r) => r['name'] as String).toList();
        expect(colNames, contains('dtw_similarity'));
      },
    );
  });

  group('Squat preferences — InMemory', () {
    test('default variant is bodyweight', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getSquatVariant(), SquatVariant.bodyweight);
    });

    test('default long-femur lifter is false', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getSquatLongFemurLifter(), isFalse);
    });

    test('round-trip squat variant', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setSquatVariant(SquatVariant.highBarBackSquat);
      expect(await repo.getSquatVariant(), SquatVariant.highBarBackSquat);
      await repo.setSquatVariant(SquatVariant.bodyweight);
      expect(await repo.getSquatVariant(), SquatVariant.bodyweight);
    });

    test('round-trip long-femur lifter', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setSquatLongFemurLifter(true);
      expect(await repo.getSquatLongFemurLifter(), isTrue);
      await repo.setSquatLongFemurLifter(false);
      expect(await repo.getSquatLongFemurLifter(), isFalse);
    });
  });

  group('Squat preferences — SQLite', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default variant (no row) returns bodyweight', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getSquatVariant(), SquatVariant.bodyweight);
    });

    test('round-trip set HBBS', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setSquatVariant(SquatVariant.highBarBackSquat);
      expect(await repo.getSquatVariant(), SquatVariant.highBarBackSquat);
    });

    test(
      'unknown variant string in DB falls back to bodyweight (corrupt DB)',
      () async {
        // Simulate a malformed row written by a future build's enum that
        // we don't recognize. The repo must NOT throw.
        await db.insert('preferences', {
          'key': 'squat_variant',
          'value': 'overheadSquat',
        });
        final repo = SqlitePreferencesRepository(db);
        expect(await repo.getSquatVariant(), SquatVariant.bodyweight);
      },
    );

    test('round-trip long-femur lifter', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setSquatLongFemurLifter(true);
      expect(await repo.getSquatLongFemurLifter(), isTrue);
      await repo.setSquatLongFemurLifter(false);
      expect(await repo.getSquatLongFemurLifter(), isFalse);
    });
  });

  group('SqlitePreferencesRepository — v1 → v2 migration', () {
    test(
      'onUpgrade creates preferences table and adds dtw_similarity column',
      () async {
        // sqflite_ffi in-memory databases are ephemeral — we can't truly
        // "close v1 then re-open as v2" inside the test harness. Instead,
        // open a fresh DB, apply the v1 schema via onCreate, then invoke
        // onUpgrade directly to verify the migration SQL is correct.
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onConfigure: onConfigure,
            onCreate: (db, _) async {
              await db.execute(ddlProfiles);
              await db.execute(ddlSessions);
              await db.execute(ddlReps);
              await db.execute(ddlFormErrors);
              await db.execute(ddlFrameTelemetry);
            },
          ),
        );

        // Simulate the 1 → 2 upgrade path directly.
        await onUpgrade(db, 1, kDbSchemaVersion);

        final tables = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='preferences'",
        );
        expect(
          tables,
          hasLength(1),
          reason: 'preferences table must exist after upgrade',
        );

        final info = await db.rawQuery('PRAGMA table_info(reps)');
        final cols = info.map((r) => r['name'] as String).toList();
        expect(
          cols,
          contains('dtw_similarity'),
          reason: 'column must be added on upgrade',
        );

        await db.close();
      },
    );
  });

  group('Schema v9 — squat min/max knee angle migration', () {
    test('v3 → v9 step-up adds both new columns', () async {
      // Build a v1-shaped baseline, then walk the migration ladder from v3
      // to current (kDbSchemaVersion). This is the path a long-dormant
      // installation upgrades through.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: onConfigure,
          onCreate: (db, _) async {
            await db.execute(ddlProfiles);
            await db.execute(ddlSessions);
            await db.execute(ddlReps);
            await db.execute(ddlFormErrors);
            await db.execute(ddlFrameTelemetry);
          },
        ),
      );

      await onUpgrade(db, 3, kDbSchemaVersion);

      final info = await db.rawQuery('PRAGMA table_info(reps)');
      final cols = info.map((r) => r['name'] as String).toList();
      expect(cols, contains('squat_min_knee_angle'));
      expect(cols, contains('squat_max_knee_angle'));

      await db.close();
    });

    test('v8 → v9 step-up adds both new columns', () async {
      // The closest realistic upgrade path: a user one schema behind ships.
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: onConfigure,
          onCreate: (db, _) async {
            await db.execute(ddlProfiles);
            await db.execute(ddlSessions);
            await db.execute(ddlReps);
            await db.execute(ddlFormErrors);
            await db.execute(ddlFrameTelemetry);
          },
        ),
      );

      await onUpgrade(db, 8, kDbSchemaVersion);

      final info = await db.rawQuery('PRAGMA table_info(reps)');
      final cols = info.map((r) => r['name'] as String).toList();
      expect(cols, contains('squat_min_knee_angle'));
      expect(cols, contains('squat_max_knee_angle'));

      await db.close();
    });

    test(
      'pre-v9 rep rows pick up NULL for both new columns on upgrade',
      () async {
        // Seed a v1 DB with one rep row, then walk to current. The pre-existing
        // row must survive and both new columns must be NULL on it.
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onConfigure: onConfigure,
            onCreate: (db, _) async {
              await db.execute(ddlProfiles);
              await db.execute(ddlSessions);
              await db.execute(ddlReps);
              await db.execute(ddlFormErrors);
              await db.execute(ddlFrameTelemetry);
            },
          ),
        );

        await db.insert('sessions', <String, Object?>{
          'exercise': 'squat',
          'started_at': 1_700_000_000_000,
          'duration_ms': 0,
          'total_reps': 1,
          'total_sets': 1,
          'fatigue_detected': 0,
          'asymmetry_detected': 0,
          'eccentric_too_fast_count': 0,
        });
        final sessionId =
            (await db.query(
                  'sessions',
                  orderBy: 'id DESC',
                  limit: 1,
                )).first['id']
                as int;
        await db.insert('reps', <String, Object?>{
          'session_id': sessionId,
          'rep_index': 1,
          'quality': 0.8,
        });

        await onUpgrade(db, 1, kDbSchemaVersion);

        final reps = await db.query('reps');
        expect(reps, hasLength(1));
        expect(reps.first['squat_min_knee_angle'], isNull);
        expect(reps.first['squat_max_knee_angle'], isNull);
        // Sanity: the row's pre-existing fields survive.
        expect(reps.first['rep_index'], 1);
        expect(reps.first['quality'], 0.8);

        await db.close();
      },
    );
  });
}
