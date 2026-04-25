/// SQLite schema for FiTrack's local persistence layer.
///
/// v1 (WP5): profiles, sessions, reps, form_errors, frame_telemetry.
/// v2 (T5.3): adds `preferences` table + `reps.dtw_similarity` column.
///
/// Five tables (v1) + one table (v2):
///   - `profiles`         — JSON-blob per-exercise ROM profile (PR1)
///   - `sessions`         — one row per completed workout (PR2 writes)
///   - `reps`             — one row per rep; curl-specific columns nullable (PR2 writes)
///   - `form_errors`      — aggregate per-session form errors (PR2 writes)
///   - `frame_telemetry`  — shape reserved for T2.4 dataset work; empty in WP5
///   - `preferences`      — key/value settings store (v2, T5.3)
///
/// Foreign keys are OFF by default on each sqflite connection. `onConfigure`
/// must run `PRAGMA foreign_keys = ON` — without it, ON DELETE CASCADE in the
/// DDL below is silently ignored. See `.agent_brain/WISDOM.md`.
library;

import 'package:sqflite/sqflite.dart';

/// On-disk schema version. Bump when any CREATE/ALTER landing in `onCreate` or
/// `onUpgrade` changes. Independent of `CurlRomProfile.schemaVersion` which
/// tags the JSON blob inside `profiles.profile_json`.
const int kDbSchemaVersion = 2;

const String ddlProfiles = '''
CREATE TABLE profiles (
  profile_key    TEXT    NOT NULL PRIMARY KEY,
  profile_json   TEXT    NOT NULL,
  schema_version INTEGER NOT NULL DEFAULT 1,
  updated_at     INTEGER NOT NULL
)
''';

const String ddlSessions = '''
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

const String ddlReps = '''
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
  rejected_outlier INTEGER,
  concentric_ms    INTEGER
)
''';

const String ddlFormErrors = '''
CREATE TABLE form_errors (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  error      TEXT    NOT NULL,
  count      INTEGER NOT NULL DEFAULT 1
)
''';

const String ddlFrameTelemetry = '''
CREATE TABLE frame_telemetry (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  frame_index INTEGER NOT NULL,
  elbow_angle REAL,
  state       TEXT,
  captured_at INTEGER NOT NULL
)
''';

/// v2: key/value settings store. Reusable for future toggles (TTS, haptics).
const String ddlPreferences = '''
CREATE TABLE IF NOT EXISTS preferences (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
''';

const List<String> ddlIndexes = <String>[
  'CREATE INDEX idx_sessions_exercise_started ON sessions(exercise, started_at DESC)',
  'CREATE INDEX idx_sessions_started          ON sessions(started_at DESC)',
  'CREATE INDEX idx_reps_session              ON reps(session_id)',
  'CREATE INDEX idx_form_errors_session       ON form_errors(session_id)',
  'CREATE INDEX idx_frame_telemetry_session   ON frame_telemetry(session_id)',
];

/// Runs on EVERY connection open (new and cached). Sqflite opens with
/// `foreign_keys=OFF` by default; enable here so CASCADE deletes fire.
Future<void> onConfigure(Database db) async {
  await db.execute('PRAGMA foreign_keys = ON');
}

/// Runs once, the first time a DB at `version: kDbSchemaVersion` is opened.
Future<void> onCreate(Database db, int version) async {
  await db.execute(ddlProfiles);
  await db.execute(ddlSessions);
  await db.execute(ddlReps);
  await db.execute(ddlFormErrors);
  await db.execute(ddlFrameTelemetry);
  await db.execute(ddlPreferences);
  // v2 columns included in fresh DDL above — no ALTER TABLE needed for new installs.
  await db.execute('ALTER TABLE reps ADD COLUMN dtw_similarity REAL');
  for (final idx in ddlIndexes) {
    await db.execute(idx);
  }
}

/// Incremental migrations applied on open when the on-disk version is older.
Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion < 2) {
    // Both DDLs are additive — safe to run on any v1 database.
    await db.execute(ddlPreferences);
    await db.execute('ALTER TABLE reps ADD COLUMN dtw_similarity REAL');
  }
}
