import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('DatabaseService (in-memory schema)', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('creates all five tables on first open', () async {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'android_%' "
        'ORDER BY name',
      );
      final names = rows.map((r) => r['name'] as String).toList();
      expect(
        names,
        containsAll(<String>[
          'form_errors',
          'frame_telemetry',
          'profiles',
          'reps',
          'sessions',
        ]),
      );
    });

    test('creates all expected indexes', () async {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' "
        "AND name LIKE 'idx_%' ORDER BY name",
      );
      final names = rows.map((r) => r['name'] as String).toList();
      expect(
        names,
        containsAll(<String>[
          'idx_form_errors_session',
          'idx_frame_telemetry_session',
          'idx_reps_session',
          'idx_sessions_exercise_started',
          'idx_sessions_started',
        ]),
      );
    });

    test('foreign_keys pragma is ON after open', () async {
      final result = await db.rawQuery('PRAGMA foreign_keys');
      expect(result.first.values.first, 1);
    });

    test('CASCADE delete fires with foreign_keys ON', () async {
      final sessionId = await db.insert('sessions', <String, Object?>{
        'exercise': 'bicepsCurl',
        'started_at': 1000,
        'duration_ms': 30000,
        'total_reps': 2,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
        'schema_version': 1,
      });
      await db.insert('reps', <String, Object?>{
        'session_id': sessionId,
        'rep_index': 1,
      });
      await db.insert('reps', <String, Object?>{
        'session_id': sessionId,
        'rep_index': 2,
      });

      expect(
        Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM reps')),
        2,
      );

      await db.delete(
        'sessions',
        where: 'id = ?',
        whereArgs: <Object?>[sessionId],
      );

      expect(
        Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM reps')),
        0,
        reason: 'CASCADE must drop dependent reps',
      );
    });

    test(
      'reps.concentric_ms column is NULL-tolerant (ships ready for PR4)',
      () async {
        // Per plan: PR1 ships the column; PR4 starts writing. Verify INSERT
        // without concentric_ms succeeds and SELECT returns null.
        final sessionId = await db.insert('sessions', <String, Object?>{
          'exercise': 'bicepsCurl',
          'started_at': 1000,
          'duration_ms': 30000,
          'total_reps': 1,
          'total_sets': 1,
          'fatigue_detected': 0,
          'asymmetry_detected': 0,
          'eccentric_too_fast_count': 0,
          'schema_version': 1,
        });
        await db.insert('reps', <String, Object?>{
          'session_id': sessionId,
          'rep_index': 1,
        });

        final rows = await db.query('reps');
        expect(rows.first['concentric_ms'], isNull);
      },
    );
  });

  group('DatabaseService (on-disk reopen)', () {
    late Directory tmp;

    setUp(() {
      tmp = makeTempDocsDir('fitrack_db_reopen_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('rows persist across close + reopen', () async {
      final path = '${tmp.path}/fitrack.db';

      // Open, insert, close.
      final db1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
          onCreate: (d, _) async {
            // Minimal schema for this specific test — mirror the full schema
            // to avoid pulling in the entire service; this test is only about
            // "does sqflite persist across close+reopen at all".
            await d.execute('''
              CREATE TABLE profiles (
                profile_key TEXT PRIMARY KEY,
                profile_json TEXT NOT NULL,
                schema_version INTEGER NOT NULL DEFAULT 1,
                updated_at INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      await db1.insert('profiles', <String, Object?>{
        'profile_key': 'curl_profile_v1',
        'profile_json': '{"schemaVersion":1}',
        'schema_version': 1,
        'updated_at': 42,
      });
      await db1.close();

      // Reopen, read.
      final db2 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        ),
      );
      final rows = await db2.query('profiles');
      expect(rows, hasLength(1));
      expect(rows.first['profile_key'], 'curl_profile_v1');
      expect(rows.first['updated_at'], 42);
      await db2.close();
    });
  });
}
