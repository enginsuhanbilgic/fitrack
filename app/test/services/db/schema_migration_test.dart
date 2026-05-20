/// Schema migration v9 → v10 test (Gap 14).
///
/// Opens a v9-shaped DB using an inlined v9 `onCreate` snapshot, seeds one
/// row in each affected table, closes, reopens at the current version with
/// the production `onUpgrade` running, and asserts:
///   - `is_demo` column exists on `sessions` and `user_profile`
///   - pre-existing rows pick up `is_demo = 0` via DEFAULT
///   - new rows can be inserted with `is_demo = 1`
library;

import 'package:fitrack/services/db/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  setUpAll(initSqfliteFfi);

  // sqflite_ffi's in-memory DB lives for the duration of the connection.
  // We can't truly "close and reopen at a new version" the way a real on-disk
  // DB does — but we CAN open at version 9 with our inlined onCreate, then
  // invoke `onUpgrade(db, 9, 10)` directly. This validates the SQL works on
  // a v9-shaped fixture even though the connection itself never re-opens.
  group('v9 → v10: is_demo columns', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 9,
          onConfigure: onConfigure,
          onCreate: _v9OnCreate,
        ),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('sessions gains is_demo column with DEFAULT 0', () async {
      await db.insert('sessions', <String, Object?>{
        'exercise': 'squat',
        'started_at': 1_700_000_000_000,
        'duration_ms': 60000,
        'total_reps': 5,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
        'schema_version': 1,
      });

      await onUpgrade(db, 9, kDbSchemaVersion);

      final cols = (await db.rawQuery(
        'PRAGMA table_info(sessions)',
      )).map((r) => r['name'] as String).toList();
      expect(cols, contains('is_demo'));

      final rows = await db.query('sessions');
      expect(rows, hasLength(1));
      expect(rows.first['is_demo'], 0);
    });

    test('user_profile gains is_demo column with DEFAULT 0', () async {
      await db.insert('user_profile', <String, Object?>{
        'id': 1,
        'display_name': 'Pre-v10 User',
        'created_at': 1_700_000_000_000,
        'updated_at': 1_700_000_000_000,
      });

      await onUpgrade(db, 9, kDbSchemaVersion);

      final cols = (await db.rawQuery(
        'PRAGMA table_info(user_profile)',
      )).map((r) => r['name'] as String).toList();
      expect(cols, contains('is_demo'));

      final rows = await db.query('user_profile');
      expect(rows, hasLength(1));
      expect(rows.first['is_demo'], 0);
      expect(rows.first['display_name'], 'Pre-v10 User');
    });

    test('post-upgrade inserts can set is_demo=1', () async {
      await onUpgrade(db, 9, kDbSchemaVersion);
      await db.insert('sessions', <String, Object?>{
        'exercise': 'squat',
        'started_at': 1_700_000_000_000,
        'duration_ms': 60000,
        'total_reps': 5,
        'total_sets': 1,
        'fatigue_detected': 0,
        'asymmetry_detected': 0,
        'eccentric_too_fast_count': 0,
        'schema_version': 1,
        'is_demo': 1,
      });
      final rows = await db.query('sessions');
      expect(rows.first['is_demo'], 1);
    });
  });
}

/// Snapshot of the schema v9 `onCreate` shape. Re-creates every table that
/// existed at v9 PLUS replays every v2..v9 ALTER so the DB reaches v9's
/// terminal state. Intentionally does NOT include v10's `is_demo` columns —
/// that's what `onUpgrade(db, 9, 10)` must add.
Future<void> _v9OnCreate(Database db, int _) async {
  await db.execute(ddlProfiles);
  await db.execute(v9SessionsDdl);
  await db.execute(v1RepsDdl);
  await db.execute(ddlFormErrors);
  await db.execute(ddlFrameTelemetry);
  await db.execute(ddlPreferences);
  await db.execute(v9UserProfileDdl);
  // v2..v9 reps ALTERs.
  await db.execute('ALTER TABLE reps ADD COLUMN dtw_similarity REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN squat_lean_deg REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN squat_knee_shift_ratio REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN squat_heel_lift_ratio REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN squat_variant TEXT');
  await db.execute('ALTER TABLE reps ADD COLUMN biceps_lean_deg REAL');
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_shoulder_drift_ratio REAL',
  );
  await db.execute('ALTER TABLE reps ADD COLUMN biceps_elbow_drift_ratio REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN biceps_back_lean_deg REAL');
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_elbow_drift_signed REAL',
  );
  await db.execute('ALTER TABLE reps ADD COLUMN biceps_shrug_ratio REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN biceps_front_swing_ratio REAL');
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_front_depth_swing_ratio REAL',
  );
  await db.execute('ALTER TABLE reps ADD COLUMN squat_min_knee_angle REAL');
  await db.execute('ALTER TABLE reps ADD COLUMN squat_max_knee_angle REAL');
}
