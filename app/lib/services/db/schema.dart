/// SQLite schema for FiTrack's local persistence layer.
///
/// v1 (WP5): profiles, sessions, reps, form_errors, frame_telemetry.
/// v2 (T5.3): adds `preferences` table + `reps.dtw_similarity` column.
/// v3 (Squat Master Rebuild follow-up): adds 4 nullable squat columns to `reps`
/// v4 (bicepsCurl split): rewrites `sessions.exercise = 'bicepsCurl'` rows to
///     `'bicepsCurlFront'` so legacy sessions render correctly in History after
///     the enum split. Assumption: all real sessions before this PR were filmed
///     facing the camera (front view) — valid for the MVP dataset.
///     so per-rep lean / knee-shift / heel-lift ratios + variant persist
///     across sessions. Enables the telemetry-driven retune loop documented
///     in `docs/squat/SQUAT_MASTER_SPEC.md §10.3`. Curl + push-up rows leave
///     all four columns NULL.
/// v5 (biceps side-view metrics): adds 5 nullable biceps columns to `reps`
///     (`biceps_lean_deg`, `biceps_shoulder_drift_ratio`,
///     `biceps_elbow_drift_ratio`, `biceps_back_lean_deg`,
///     `biceps_elbow_drift_signed`). Populated only for `bicepsCurlSide`
///     rows. NULL on front curl, squat, push-up, and pre-v5 rows. The
///     signed column carries the elbow-drift sign at the frame where the
///     magnitude peaked — lets the retune split forward-elbow (front-delt
///     cheat) vs. back-elbow (rare; setup) without ambiguity. Opens the
///     telemetry channel for the future Phase D-v2 side-view threshold
///     retune (plan `federated-tickling-sunset` PR 4).
/// v6 (biceps side-view shrug/elbow-rise): adds 2 nullable biceps columns
///     (`biceps_shrug_ratio`, `biceps_elbow_rise_ratio`). Completes the
///     retune telemetry channel for kShrugThreshold and kElbowRiseThreshold.
/// v7 (biceps front-view swing/depth-swing): adds 2 nullable biceps
///     columns (`biceps_front_swing_ratio`, `biceps_front_depth_swing_ratio`).
///     Populated only for `bicepsCurlFront` rows. NULL on side curl, squat,
///     push-up, and pre-v7 rows. Closes the per-rep persistence gap for
///     front-view metrics so the strict-mode recap card can re-grade
///     swing + depth-swing at High sensitivity.
/// v8 (user profile): adds the single-row `user_profile` table for
///     local-only display name, demographics (age/gender/height/weight),
///     fitness experience + primary goal, and a JSON-encoded list of
///     user-defined goals. Pure CREATE TABLE — no existing rows touched.
///     Storage convention is metric (cm, kg); the [Units] preference only
///     controls display + input. The `id INTEGER PRIMARY KEY CHECK (id = 1)`
///     constraint enforces single-row semantics until multi-user auth lands
///     (then the CHECK is dropped and `id` becomes a real user FK).
/// v9 (squat per-rep min/max knee angle): adds 2 nullable columns
///     (`squat_min_knee_angle`, `squat_max_knee_angle`) to `reps`.
///     Populated only on squat rows. NULL on curl, push-up, and pre-v9 rows.
///     Foundation for the squat personal-calibration + auto-calibration
///     pipeline (analogous to the per-rep min/max angles the curl pipeline
///     already persists for ROM profile derivation). Part 1 of the squat
///     pipeline overhaul (2026-05-13).
/// v10 (demo mode): adds `is_demo INTEGER NOT NULL DEFAULT 0` to `sessions`
///     and `user_profile`. Tags rows owned by the Demo Mode seed so they
///     can be wiped+restored without touching real user data. Demo ROM
///     profiles use a separate keyspace in the `profiles` table
///     (`demo_curl_profile_v1`, `demo_squat_profile_v1`,
///     `demo_push_up_profile_v1`) rather than a flag column — see ADR-2 in
///     `plans_of_claude/demo-mode-toggle.md`. `reps` + `form_errors` are
///     NOT tagged — they cascade-delete with their parent `sessions` row.
///
/// Six tables (v1) + one table (v2) + one table (v8):
///   - `profiles`         — JSON-blob per-exercise ROM profile (PR1)
///   - `sessions`         — one row per completed workout (PR2 writes)
///   - `reps`             — one row per rep; curl-specific columns nullable (PR2 writes)
///   - `form_errors`      — aggregate per-session form errors (PR2 writes)
///   - `frame_telemetry`  — shape reserved for T2.4 dataset work; empty in WP5
///   - `preferences`      — key/value settings store (v2, T5.3)
///   - `user_profile`     — single-row local user profile (v8)
///
/// Foreign keys are OFF by default on each sqflite connection. `onConfigure`
/// must run `PRAGMA foreign_keys = ON` — without it, ON DELETE CASCADE in the
/// DDL below is silently ignored. See `.agent_brain/WISDOM.md`.
library;

import 'package:sqflite/sqflite.dart';

/// On-disk schema version. Bump when any CREATE/ALTER landing in `onCreate` or
/// `onUpgrade` changes. Independent of `CurlRomProfile.schemaVersion` which
/// tags the JSON blob inside `profiles.profile_json`.
const int kDbSchemaVersion = 10;

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
  schema_version           INTEGER NOT NULL DEFAULT 1,
  is_demo                  INTEGER NOT NULL DEFAULT 0
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

/// v8: single-row local user profile. The `CHECK (id = 1)` constraint enforces
/// the singleton invariant — any attempt to INSERT a second row fails. When
/// multi-user auth lands (`PRODUCTION_ROADMAP.md` Phase 4), drop the CHECK and
/// promote `id` to a real user FK; the column shape is already compatible.
///
/// All demographic fields are NULLable — a freshly-onboarded user may save
/// only a display name. Heights are stored in cm and weights in kg regardless
/// of the user's [Units] preference; conversion happens at the UI boundary.
const String ddlUserProfile = '''
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
  updated_at    INTEGER NOT NULL,
  is_demo       INTEGER NOT NULL DEFAULT 0
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
  await db.execute(ddlUserProfile);
  // v2 + v3 ALTERs against the freshly-created `reps` table.
  // (Inlined here rather than added to `ddlReps` so the DDL constant stays
  // a faithful "v1 baseline" — easier to reason about migrations.)
  await db.execute(
    'ALTER TABLE reps ADD COLUMN dtw_similarity              REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_lean_deg              REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_knee_shift_ratio      REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_heel_lift_ratio       REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_variant               TEXT',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_lean_deg             REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_shoulder_drift_ratio REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_elbow_drift_ratio    REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_back_lean_deg        REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_elbow_drift_signed   REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_shrug_ratio          REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_elbow_rise_ratio     REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_front_swing_ratio    REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN biceps_front_depth_swing_ratio REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_min_knee_angle           REAL',
  );
  await db.execute(
    'ALTER TABLE reps ADD COLUMN squat_max_knee_angle           REAL',
  );
  for (final idx in ddlIndexes) {
    await db.execute(idx);
  }
}

/// Incremental migrations applied on open when the on-disk version is older.
///
/// Each `if (oldVersion < N)` block is **purely additive**: ALTER TABLE ADD
/// COLUMN with a nullable type so legacy rows automatically pick up NULL.
/// Never reorder; never make a block conditional on the *new* version.
Future<void> onUpgrade(Database db, int oldVersion, int newVersion) async {
  if (oldVersion < 2) {
    // v1 → v2: DTW reference scoring + preferences table.
    await db.execute(ddlPreferences);
    await db.execute('ALTER TABLE reps ADD COLUMN dtw_similarity REAL');
  }
  if (oldVersion < 3) {
    // v2 → v3: per-rep squat metrics (Squat Master Rebuild follow-up).
    // Nullable, NULL for all pre-v3 rows AND for non-squat rows. Enables
    // the telemetry-driven retune loop without breaking any existing data.
    await db.execute('ALTER TABLE reps ADD COLUMN squat_lean_deg         REAL');
    await db.execute('ALTER TABLE reps ADD COLUMN squat_knee_shift_ratio REAL');
    await db.execute('ALTER TABLE reps ADD COLUMN squat_heel_lift_ratio  REAL');
    await db.execute('ALTER TABLE reps ADD COLUMN squat_variant          TEXT');
  }
  if (oldVersion < 4) {
    // v3 → v4: rewrite legacy 'bicepsCurl' rows to 'bicepsCurlFront'.
    // All real sessions before this PR were filmed facing the camera, so
    // front-view is the correct attribution. Existing side-view rows did not
    // exist in practice (auto-detect was broken before this PR).
    await db.execute(
      "UPDATE sessions SET exercise = 'bicepsCurlFront' WHERE exercise = 'bicepsCurl'",
    );
  }
  if (oldVersion < 5) {
    // v4 → v5: per-rep biceps-curl side-view form metrics. Nullable; NULL
    // for all pre-v5 rows AND for non-side-view rows (front curl, squat,
    // push-up). Opens the telemetry channel for the future Phase D-v2
    // side-view threshold retune (plan `federated-tickling-sunset` PR 4).
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_lean_deg             REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_shoulder_drift_ratio REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_elbow_drift_ratio    REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_back_lean_deg        REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_elbow_drift_signed   REAL',
    );
  }
  if (oldVersion < 6) {
    // v5 → v6: peak shrug + elbow-rise ratios. Nullable; NULL for all
    // pre-v6 rows AND for non-side-view rows. Opens the data-driven retune
    // channel for kShrugThreshold and kElbowRiseThreshold.
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_shrug_ratio          REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_elbow_rise_ratio     REAL',
    );
  }
  if (oldVersion < 7) {
    // v6 → v7: peak swing + depth-swing for FRONT-view curl. Nullable; NULL
    // for all pre-v7 rows AND for non-front-view rows (side curl, squat,
    // push-up). Enables the strict-mode recap card to re-grade front-view
    // swing + depth-swing at High sensitivity using stored per-rep values
    // rather than re-running the analyzer.
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_front_swing_ratio    REAL',
    );
    await db.execute(
      'ALTER TABLE reps ADD COLUMN biceps_front_depth_swing_ratio REAL',
    );
  }
  if (oldVersion < 8) {
    // v7 → v8: single-row local user profile. Pure CREATE TABLE — touches no
    // existing rows. Anonymous installs upgrade silently with zero data loss;
    // the profile is created the first time the user opens Edit Profile.
    await db.execute(ddlUserProfile);
  }
  if (oldVersion < 9) {
    // v8 → v9: per-rep squat min/max knee angle. Purely additive; both
    // columns are nullable so all pre-v9 squat rows (and every curl /
    // push-up row regardless of version) automatically pick up NULL.
    // Foundation for the squat personal-calibration + auto-calibration
    // pipeline — `SquatRepMetrics.{minKneeAngle, maxKneeAngle}` round-trip
    // here.
    await db.execute('ALTER TABLE reps ADD COLUMN squat_min_knee_angle REAL');
    await db.execute('ALTER TABLE reps ADD COLUMN squat_max_knee_angle REAL');
  }
  if (oldVersion < 10) {
    // v9 → v10: demo mode tagging on `sessions` and `user_profile`.
    // Pure ALTER TABLE ADD COLUMN with DEFAULT 0 — all existing rows
    // pick up `is_demo = 0` automatically, so the change is invisible
    // to all existing reads. The `profiles` table is intentionally
    // NOT modified — demo ROM profiles use a separate keyspace
    // (`demo_curl_profile_v1`, etc.) per ADR-2 of the demo-mode plan.
    // `reps` + `form_errors` are NOT tagged — they cascade-delete with
    // their parent `sessions` row via the existing FK ON DELETE CASCADE.
    await _addColumnIfNotExists(
      db,
      'sessions',
      'is_demo',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _addColumnIfNotExists(
      db,
      'user_profile',
      'is_demo',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }
}

/// Safely adds a column to a table only if it does not already exist.
/// Prevents migration crashes when a developer updates a DDL constant and a
/// migration script in the same PR, causing the column to be created twice
/// for some users (VGV I3).
Future<void> _addColumnIfNotExists(
  Database db,
  String table,
  String column,
  String definition,
) async {
  final result = await db.rawQuery('PRAGMA table_info($table)');
  final exists = result.any((row) => row['name'] == column);
  if (!exists) {
    await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
  }
}
