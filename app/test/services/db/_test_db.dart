/// Shared test infrastructure for SQLite-backed repository tests.
///
/// Uses `sqflite_common_ffi` + `inMemoryDatabasePath` so tests run on the
/// pure-Dart VM without a device/emulator. Matches the project idiom of real
/// I/O over mocks — an in-memory SQLite instance gives authentic transaction
/// and foreign-key semantics rather than a hand-rolled stub.
library;

import 'dart:io';

import 'package:fitrack/services/db/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Call once per test file, at top of `main()`, before any async setup.
void initSqfliteFfi() {
  sqfliteFfiInit();
}

/// Opens a fresh in-memory database at the current schema version, with
/// `foreign_keys = ON` (required for CASCADE deletes to work).
Future<Database> openTestDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: kDbSchemaVersion,
      onConfigure: onConfigure,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    ),
  );
}

/// Creates a temporary docs directory for tests that need a filesystem path
/// (e.g. the JSON migrator). Caller is responsible for `deleteSync(recursive:
/// true)` in `tearDown`.
Directory makeTempDocsDir(String prefix) {
  return Directory.systemTemp.createTempSync(prefix);
}

/// v1-baseline DDL for `sessions` — without any of the additive columns
/// (`is_demo`, `eccentric_too_fast_count`, `schema_version`) that landed in
/// later migrations. Migration tests should use this when seeding an
/// older-version DB so the live `onUpgrade` can re-apply each step from a
/// clean baseline.
const String v1SessionsDdl = '''
CREATE TABLE sessions (
  id                 INTEGER PRIMARY KEY AUTOINCREMENT,
  exercise           TEXT    NOT NULL,
  started_at         INTEGER NOT NULL,
  duration_ms        INTEGER NOT NULL,
  total_reps         INTEGER NOT NULL,
  total_sets         INTEGER NOT NULL,
  average_quality    REAL,
  detected_view      TEXT,
  fatigue_detected   INTEGER NOT NULL DEFAULT 0,
  asymmetry_detected INTEGER NOT NULL DEFAULT 0
)
''';

/// v1-baseline DDL for `reps` — column shape before the chain of v2..v9
/// ALTERs. Includes only the original columns.
const String v1RepsDdl = '''
CREATE TABLE reps (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id       INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  rep_index        INTEGER NOT NULL,
  quality          REAL,
  min_angle        REAL,
  max_angle        REAL,
  side             TEXT,
  view             TEXT,
  threshold_source TEXT,
  bucket_updated   INTEGER,
  rejected_outlier INTEGER
)
''';

/// v9-baseline DDL for `sessions` — everything BEFORE `is_demo`. Used by the
/// v9 → v10 schema migration test fixture.
const String v9SessionsDdl = '''
CREATE TABLE sessions (
  id                       INTEGER PRIMARY KEY AUTOINCREMENT,
  exercise                 TEXT    NOT NULL,
  started_at               INTEGER NOT NULL,
  duration_ms              INTEGER NOT NULL,
  total_reps               INTEGER NOT NULL,
  total_sets               INTEGER NOT NULL,
  average_quality          REAL,
  detected_view            TEXT,
  fatigue_detected         INTEGER NOT NULL DEFAULT 0,
  asymmetry_detected       INTEGER NOT NULL DEFAULT 0,
  eccentric_too_fast_count INTEGER NOT NULL DEFAULT 0,
  schema_version           INTEGER NOT NULL DEFAULT 1
)
''';

/// v9-baseline DDL for `user_profile` — before `is_demo` (v10).
const String v9UserProfileDdl = '''
CREATE TABLE IF NOT EXISTS user_profile (
  id            INTEGER PRIMARY KEY CHECK (id = 1),
  display_name  TEXT,
  avatar_emoji  TEXT,
  age           INTEGER,
  gender        TEXT,
  height_cm     REAL,
  weight_kg     REAL,
  experience    TEXT,
  primary_goal  TEXT,
  goals_json    TEXT,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL
)
''';
