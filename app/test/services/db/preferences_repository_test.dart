import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:fitrack/services/db/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository', () {
    test('default is false', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getEnableDtwScoring(), isFalse);
    });

    test('round-trip set true then false', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setEnableDtwScoring(true);
      expect(await repo.getEnableDtwScoring(), isTrue);
      await repo.setEnableDtwScoring(false);
      expect(await repo.getEnableDtwScoring(), isFalse);
    });
  });

  group('SqlitePreferencesRepository — current schema (v2)', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default (no row) returns false', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getEnableDtwScoring(), isFalse);
    });

    test('set true, get true', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setEnableDtwScoring(true);
      expect(await repo.getEnableDtwScoring(), isTrue);
    });

    test('idempotent set — second write replaces first', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setEnableDtwScoring(true);
      await repo.setEnableDtwScoring(false);
      expect(await repo.getEnableDtwScoring(), isFalse);
    });

    test('preferences table exists in v2 schema', () async {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='preferences'",
      );
      expect(tables, hasLength(1));
    });

    test('reps table has dtw_similarity column in v2 schema', () async {
      final info = await db.rawQuery('PRAGMA table_info(reps)');
      final colNames = info.map((r) => r['name'] as String).toList();
      expect(colNames, contains('dtw_similarity'));
    });
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
}
