/// Persistence for completed workout sessions.
///
/// PR2 lands [SqliteSessionRepository] + the DTO surface
/// (`SessionSummary`, `SessionDetail`, `RepRow`, `toCurlRepRecord`).
/// PR3 consumes the read paths for the History screen; PR4 starts writing
/// `reps.concentric_ms` and wires `recentConcentricDurations` to real data
/// (column already exists from PR1 schema, NULL-tolerant).
///
/// Keeping the interface stable from PR1 kept that PR's `AppServicesScope`
/// shape unchanged; PR2 just swaps `InMemorySessionRepository` for the Sqlite
/// impl in the bootstrap.
library;

import 'package:sqflite/sqflite.dart';

import '../../core/types.dart';
import '../../view_models/workout_view_model.dart' show WorkoutCompletedEvent;
import 'session_dtos.dart';

abstract class SessionRepository {
  /// Writes one `sessions` row + N `reps` rows + M `form_errors` rows in a
  /// single transaction. Returns the new session id.
  ///
  /// `concentricDurations` is index-aligned with `event.curlRepRecords` (or
  /// with `event.repQualities` for non-curl sessions). Any `null` entry
  /// persists as NULL in `reps.concentric_ms`. Empty list = write NULL for
  /// every rep (pre-WP5.4 behavior + non-curl sessions).
  ///
  /// `squatRepMetrics` is index-aligned with `event.squatRepMetrics` (which
  /// is in turn index-aligned with the rep order). Each entry's
  /// `leanDeg` / `kneeShiftRatio` / `heelLiftRatio` lands in the matching
  /// schema-v3 column on the `reps` row; `event.squatVariant.name` lands in
  /// `squat_variant`. Empty list = NULL for every rep (curl + push-up
  /// sessions, or squat sessions on schema-v2 builds).
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
    List<Duration?> concentricDurations = const [],

    /// Per-rep DTW similarity scores (0.0–1.0), index-aligned with
    /// `event.curlRepRecords`. Null entries and missing indices persist as NULL.
    List<double?> dtwSimilarities = const [],
  });

  /// History list source. Newest first (`started_at DESC`). `exercise = null`
  /// returns all exercises merged.
  Future<List<SessionSummary>> listSessions({
    ExerciseType? exercise,
    int limit = 100,
    int offset = 0,
  });

  /// Returns null when the session was deleted or never existed.
  Future<SessionDetail?> getSession(int sessionId);

  /// Cascades to `reps` + `form_errors` via FK `ON DELETE CASCADE` (relies on
  /// `PRAGMA foreign_keys = ON` set by [onConfigure] in `schema.dart`).
  Future<void> deleteSession(int sessionId);

  /// Recent concentric durations for the fatigue-baseline feedback loop (PR4).
  /// Returns `<Duration>[]` in PR2/PR3 because `reps.concentric_ms` is not yet
  /// populated. Call-sites MUST treat empty as "no baseline data" — no crash.
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  });
}

class SqliteSessionRepository implements SessionRepository {
  SqliteSessionRepository(this._db);

  final Database _db;

  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
    List<Duration?> concentricDurations = const [],
    List<double?> dtwSimilarities = const [],
  }) async {
    return _db.transaction<int>((txn) async {
      final sessionId = await txn.insert('sessions', <String, Object?>{
        'exercise': event.exercise.name,
        'started_at': startedAt.millisecondsSinceEpoch,
        'duration_ms': event.sessionDuration.inMilliseconds,
        'total_reps': event.totalReps,
        'total_sets': event.totalSets,
        'average_quality': event.averageQuality,
        'detected_view': _detectedViewFor(event),
        'fatigue_detected': event.fatigueDetected ? 1 : 0,
        'asymmetry_detected': event.asymmetryDetected ? 1 : 0,
        'eccentric_too_fast_count': event.eccentricTooFastCount,
        'schema_version': 1,
      });

      // Curl path: one row per CurlRepRecord with all curl columns populated.
      // Non-curl: one row per repQualities entry with only rep_index+quality.
      if (event.curlRepRecords.isNotEmpty) {
        // Side-view per-rep biceps metrics are index-aligned with the rep
        // order (1-based via `repIndex`), populated only for `bicepsCurlSide`
        // sessions. Front-curl, squat, and push-up rows leave the four
        // schema-v5 columns NULL.
        final isCurlSide = event.exercise == ExerciseType.bicepsCurlSide;
        for (final r in event.curlRepRecords) {
          final quality =
              r.repIndex >= 1 && r.repIndex <= event.repQualities.length
              ? event.repQualities[r.repIndex - 1]
              : null;
          final concentricMs = _concentricMsAt(
            concentricDurations,
            r.repIndex - 1,
          );
          final dtwSimilarity = r.repIndex - 1 < dtwSimilarities.length
              ? dtwSimilarities[r.repIndex - 1]
              : null;
          final bicepsMetric =
              isCurlSide && r.repIndex - 1 < event.bicepsSideRepMetrics.length
              ? event.bicepsSideRepMetrics[r.repIndex - 1]
              : null;
          await txn.insert('reps', <String, Object?>{
            'session_id': sessionId,
            'rep_index': r.repIndex,
            'quality': quality,
            'min_angle': r.minAngle,
            'max_angle': r.maxAngle,
            'side': r.side.name,
            'view': r.view.name,
            'threshold_source': r.source.name,
            'bucket_updated': r.bucketUpdated ? 1 : 0,
            'rejected_outlier': r.rejectedOutlier ? 1 : 0,
            'concentric_ms': concentricMs,
            'dtw_similarity': dtwSimilarity,
            'biceps_lean_deg': bicepsMetric?.leanDeg,
            'biceps_shoulder_drift_ratio': bicepsMetric?.shoulderDriftRatio,
            'biceps_elbow_drift_ratio': bicepsMetric?.elbowDriftRatio,
            'biceps_back_lean_deg': bicepsMetric?.backLeanDeg,
            'biceps_elbow_drift_signed': bicepsMetric?.elbowDriftSigned,
            'biceps_shrug_ratio': bicepsMetric?.shrugRatio,
            'biceps_elbow_rise_ratio': bicepsMetric?.elbowRiseRatio,
          });
        }
      } else {
        // Non-curl path. Squat sessions populate the schema-v3 squat columns
        // when per-rep metrics are present; push-up + pre-rebuild squat rows
        // leave them NULL.
        final isSquat = event.exercise == ExerciseType.squat;
        final variantName = isSquat ? event.squatVariant.name : null;
        for (var i = 0; i < event.repQualities.length; i++) {
          final squatMetric = isSquat && i < event.squatRepMetrics.length
              ? event.squatRepMetrics[i]
              : null;
          await txn.insert('reps', <String, Object?>{
            'session_id': sessionId,
            'rep_index': i + 1,
            'quality': event.repQualities[i],
            'concentric_ms': _concentricMsAt(concentricDurations, i),
            'squat_lean_deg': squatMetric?.leanDeg,
            'squat_knee_shift_ratio': squatMetric?.kneeShiftRatio,
            'squat_heel_lift_ratio': squatMetric?.heelLiftRatio,
            'squat_variant': squatMetric == null ? null : variantName,
          });
        }
      }

      for (final err in event.errorsTriggered) {
        await txn.insert('form_errors', <String, Object?>{
          'session_id': sessionId,
          'error': err.name,
          'count': 1,
        });
      }

      return sessionId;
    });
  }

  /// Persist `detected_view` only when it's a real curl view. Non-curl sessions
  /// always have `CurlCameraView.unknown`; store NULL for those so the column
  /// carries real information.
  String? _detectedViewFor(WorkoutCompletedEvent event) {
    if (!event.exercise.isCurl) return null;
    if (event.detectedView == CurlCameraView.unknown) return null;
    return event.detectedView.name;
  }

  /// Lookup `concentricDurations[i]` safely. Out-of-bounds / null → null
  /// column. Callers do NOT need to pre-pad the list.
  static int? _concentricMsAt(List<Duration?> durations, int index) {
    if (index < 0 || index >= durations.length) return null;
    return durations[index]?.inMilliseconds;
  }

  @override
  Future<List<SessionSummary>> listSessions({
    ExerciseType? exercise,
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _db.query(
      'sessions',
      where: exercise == null ? null : 'exercise = ?',
      whereArgs: exercise == null ? null : <Object?>[exercise.name],
      orderBy: 'started_at DESC',
      limit: limit,
      offset: offset,
    );
    if (rows.isEmpty) return const [];

    final sessionIds = rows.map((r) => r['id'] as int).toList();
    final placeholders = List.filled(sessionIds.length, '?').join(', ');
    // One batch query — no N+1. Ranks errors by count desc within each session;
    // the RANK() emulation via ROW_NUMBER isn't available in old SQLite so we
    // fetch all and trim to top-3 in Dart.
    final errorRows = await _db.rawQuery(
      'SELECT session_id, error, count FROM form_errors '
      'WHERE session_id IN ($placeholders) '
      'ORDER BY session_id, count DESC',
      sessionIds,
    );

    // Build map: sessionId → top-3 errors (already ordered desc by count).
    final topErrorsMap = <int, List<FormError>>{};
    for (final r in errorRows) {
      final sid = r['session_id'] as int;
      final list = topErrorsMap.putIfAbsent(sid, () => []);
      if (list.length >= 3) continue;
      try {
        list.add(FormError.values.byName(r['error'] as String));
      } catch (_) {
        // Unknown enum name from a future schema version — skip gracefully.
      }
    }

    return rows
        .map((r) {
          final id = r['id'] as int;
          return _summaryFromRow(r, topErrors: topErrorsMap[id] ?? const []);
        })
        .toList(growable: false);
  }

  @override
  Future<SessionDetail?> getSession(int sessionId) async {
    final sessionRows = await _db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
      limit: 1,
    );
    if (sessionRows.isEmpty) return null;
    final sessionRow = sessionRows.first;

    final repRows = await _db.query(
      'reps',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      orderBy: 'rep_index ASC',
    );
    final errorRows = await _db.query(
      'form_errors',
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
    );

    final formErrors = <FormError, int>{};
    for (final r in errorRows) {
      final name = r['error'] as String;
      final count = r['count'] as int;
      final key = FormError.values.byName(name);
      formErrors[key] = (formErrors[key] ?? 0) + count;
    }

    return SessionDetail(
      summary: _summaryFromRow(sessionRow),
      eccentricTooFastCount:
          (sessionRow['eccentric_too_fast_count'] as int?) ?? 0,
      reps: repRows.map(_repFromRow).toList(growable: false),
      formErrors: formErrors,
    );
  }

  @override
  Future<void> deleteSession(int sessionId) async {
    await _db.delete(
      'sessions',
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async {
    // Newest-first, filtered by exercise + `started_at` within the window,
    // and only rows where `concentric_ms IS NOT NULL` (pre-WP5.4 rows + any
    // rep the analyzer failed to time stay out of the baseline).
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - window.inMilliseconds;
    // For curl exercises, pool all three variants (front, side, legacy) so the
    // fatigue baseline reflects all curl sessions regardless of view. The
    // legacy name is included as a safety net for rows that missed the v4
    // migration. Non-curl exercises query by exact name as before.
    final exerciseClause = exercise.isCurl
        ? "s.exercise IN ('bicepsCurlFront', 'bicepsCurlSide', 'bicepsCurl')"
        : 's.exercise = ?';
    final args = exercise.isCurl
        ? <Object?>[cutoff, limitReps]
        : <Object?>[exercise.name, cutoff, limitReps];
    final rows = await _db.rawQuery('''
SELECT r.concentric_ms
FROM reps AS r
JOIN sessions AS s ON s.id = r.session_id
WHERE $exerciseClause
  AND s.started_at >= ?
  AND r.concentric_ms IS NOT NULL
ORDER BY s.started_at DESC, r.rep_index ASC
LIMIT ?
''', args);
    return rows
        .map((r) => Duration(milliseconds: r['concentric_ms'] as int))
        .toList(growable: false);
  }

  // ── Row mappers ─────────────────────────────────────────

  static SessionSummary _summaryFromRow(
    Map<String, Object?> row, {
    List<FormError> topErrors = const [],
  }) {
    final detectedViewName = row['detected_view'] as String?;
    return SessionSummary(
      id: row['id'] as int,
      exercise: _parseExerciseType(row['exercise'] as String),
      startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
      duration: Duration(milliseconds: row['duration_ms'] as int),
      totalReps: row['total_reps'] as int,
      totalSets: row['total_sets'] as int,
      averageQuality: (row['average_quality'] as num?)?.toDouble(),
      detectedView: detectedViewName == null
          ? null
          : CurlCameraView.values.byName(detectedViewName),
      fatigueDetected: (row['fatigue_detected'] as int) == 1,
      asymmetryDetected: (row['asymmetry_detected'] as int) == 1,
      topErrors: topErrors,
    );
  }

  static RepRow _repFromRow(Map<String, Object?> row) {
    final sideName = row['side'] as String?;
    final viewName = row['view'] as String?;
    final sourceName = row['threshold_source'] as String?;
    final squatVariantName = row['squat_variant'] as String?;
    return RepRow(
      repIndex: row['rep_index'] as int,
      quality: (row['quality'] as num?)?.toDouble(),
      minAngle: (row['min_angle'] as num?)?.toDouble(),
      maxAngle: (row['max_angle'] as num?)?.toDouble(),
      side: sideName == null ? null : ProfileSide.values.byName(sideName),
      view: viewName == null ? null : CurlCameraView.values.byName(viewName),
      source: sourceName == null
          ? null
          : ThresholdSource.values.byName(sourceName),
      bucketUpdated: (row['bucket_updated'] as int?) == null
          ? null
          : (row['bucket_updated'] as int) == 1,
      rejectedOutlier: (row['rejected_outlier'] as int?) == null
          ? null
          : (row['rejected_outlier'] as int) == 1,
      concentricMs: row['concentric_ms'] as int?,
      dtwSimilarity: (row['dtw_similarity'] as num?)?.toDouble(),
      squatLeanDeg: (row['squat_lean_deg'] as num?)?.toDouble(),
      squatKneeShiftRatio: (row['squat_knee_shift_ratio'] as num?)?.toDouble(),
      squatHeelLiftRatio: (row['squat_heel_lift_ratio'] as num?)?.toDouble(),
      // Try/catch around `byName` so an unknown variant string from a future
      // build (e.g. `frontSquat`) doesn't poison the read path. Same pattern
      // as `SqlitePreferencesRepository.getSquatVariant`.
      squatVariant: squatVariantName == null
          ? null
          : _safeSquatVariant(squatVariantName),
      bicepsLeanDeg: (row['biceps_lean_deg'] as num?)?.toDouble(),
      bicepsShoulderDriftRatio: (row['biceps_shoulder_drift_ratio'] as num?)
          ?.toDouble(),
      bicepsElbowDriftRatio: (row['biceps_elbow_drift_ratio'] as num?)
          ?.toDouble(),
      bicepsBackLeanDeg: (row['biceps_back_lean_deg'] as num?)?.toDouble(),
      bicepsElbowDriftSigned: (row['biceps_elbow_drift_signed'] as num?)
          ?.toDouble(),
      bicepsShrugRatio: (row['biceps_shrug_ratio'] as num?)?.toDouble(),
      bicepsElbowRiseRatio: (row['biceps_elbow_rise_ratio'] as num?)
          ?.toDouble(),
    );
  }

  static ExerciseType _parseExerciseType(String name) {
    try {
      return ExerciseType.values.byName(name);
    } catch (_) {
      // Legacy 'bicepsCurl' rows not caught by the v4 migration fall back to
      // front-view — the only view that was reliably used before this PR.
      return ExerciseType.bicepsCurlFront;
    }
  }

  static SquatVariant? _safeSquatVariant(String name) {
    try {
      return SquatVariant.values.byName(name);
    } catch (_) {
      return null;
    }
  }
}

/// In-memory double. Accepts writes and serves reads back from the same list
/// so unit tests can round-trip without a SQLite dependency. Matches the
/// production semantics where needed (newest-first, exercise filter).
class InMemorySessionRepository implements SessionRepository {
  final List<_InMemorySession> _sessions = <_InMemorySession>[];
  int _nextId = 1;

  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
    List<Duration?> concentricDurations = const [],
    List<double?> dtwSimilarities = const [],
  }) async {
    final id = _nextId++;
    _sessions.add(
      _InMemorySession(
        id: id,
        event: event,
        startedAt: startedAt,
        concentricDurations: List<Duration?>.unmodifiable(concentricDurations),
      ),
    );
    return id;
  }

  @override
  Future<List<SessionSummary>> listSessions({
    ExerciseType? exercise,
    int limit = 100,
    int offset = 0,
  }) async {
    final filtered =
        _sessions
            .where((s) => exercise == null || s.event.exercise == exercise)
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return filtered
        .skip(offset)
        .take(limit)
        .map(_toSummary)
        .toList(growable: false);
  }

  @override
  Future<SessionDetail?> getSession(int sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx < 0) return null;
    final s = _sessions[idx];
    final formErrors = <FormError, int>{};
    for (final e in s.event.errorsTriggered) {
      formErrors[e] = (formErrors[e] ?? 0) + 1;
    }
    final reps = s.event.curlRepRecords.isNotEmpty
        ? s.event.curlRepRecords
              .map((r) {
                // Mirror the SQLite write path so the in-memory double round-trips
                // identically. Side-view biceps metrics are index-aligned with the
                // rep order; non-side rows leave the four columns NULL.
                final isCurlSide =
                    s.event.exercise == ExerciseType.bicepsCurlSide;
                final bicepsMetric =
                    isCurlSide &&
                        r.repIndex - 1 < s.event.bicepsSideRepMetrics.length
                    ? s.event.bicepsSideRepMetrics[r.repIndex - 1]
                    : null;
                return RepRow(
                  repIndex: r.repIndex,
                  quality:
                      r.repIndex >= 1 &&
                          r.repIndex <= s.event.repQualities.length
                      ? s.event.repQualities[r.repIndex - 1]
                      : null,
                  minAngle: r.minAngle,
                  maxAngle: r.maxAngle,
                  side: r.side,
                  view: r.view,
                  source: r.source,
                  bucketUpdated: r.bucketUpdated,
                  rejectedOutlier: r.rejectedOutlier,
                  bicepsLeanDeg: bicepsMetric?.leanDeg,
                  bicepsShoulderDriftRatio: bicepsMetric?.shoulderDriftRatio,
                  bicepsElbowDriftRatio: bicepsMetric?.elbowDriftRatio,
                  bicepsBackLeanDeg: bicepsMetric?.backLeanDeg,
                  bicepsElbowDriftSigned: bicepsMetric?.elbowDriftSigned,
                  bicepsShrugRatio: bicepsMetric?.shrugRatio,
                  bicepsElbowRiseRatio: bicepsMetric?.elbowRiseRatio,
                );
              })
              .toList(growable: false)
        : List<RepRow>.generate(s.event.repQualities.length, (i) {
            // Mirror the SQLite squat write path so test doubles round-trip
            // identically to production. Squat metrics propagate when the
            // session is a squat AND a metric exists at this index; pushup
            // and pre-rebuild squat sessions leave the columns NULL.
            final isSquat = s.event.exercise == ExerciseType.squat;
            final squatMetric = isSquat && i < s.event.squatRepMetrics.length
                ? s.event.squatRepMetrics[i]
                : null;
            return RepRow(
              repIndex: i + 1,
              quality: s.event.repQualities[i],
              squatLeanDeg: squatMetric?.leanDeg,
              squatKneeShiftRatio: squatMetric?.kneeShiftRatio,
              squatHeelLiftRatio: squatMetric?.heelLiftRatio,
              squatVariant: squatMetric == null ? null : s.event.squatVariant,
            );
          });
    return SessionDetail(
      summary: _toSummary(s),
      eccentricTooFastCount: s.event.eccentricTooFastCount,
      reps: reps,
      formErrors: formErrors,
    );
  }

  @override
  Future<void> deleteSession(int sessionId) async {
    _sessions.removeWhere((s) => s.id == sessionId);
  }

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async {
    final cutoff = DateTime.now().subtract(window);
    final filtered =
        _sessions
            .where(
              (s) =>
                  (exercise.isCurl
                      ? s.event.exercise.isCurl
                      : s.event.exercise == exercise) &&
                  !s.startedAt.isBefore(cutoff),
            )
            .toList()
          ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final out = <Duration>[];
    for (final s in filtered) {
      for (final d in s.concentricDurations) {
        if (d == null) continue;
        out.add(d);
        if (out.length >= limitReps) return out;
      }
    }
    return out;
  }

  /// Test-only snapshot of raw inserts.
  List<RecordedInsert> get recordedInserts => _sessions
      .map(
        (s) => RecordedInsert(id: s.id, event: s.event, startedAt: s.startedAt),
      )
      .toList(growable: false);

  SessionSummary _toSummary(_InMemorySession s) {
    // Mirror the SQLite batch-query logic: sort errors by count desc, take top 3.
    final counts = <FormError, int>{};
    for (final e in s.event.errorsTriggered) {
      counts[e] = (counts[e] ?? 0) + 1;
    }
    final topErrors =
        (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
            .take(3)
            .map((e) => e.key)
            .toList(growable: false);

    return SessionSummary(
      id: s.id,
      exercise: s.event.exercise,
      startedAt: s.startedAt,
      duration: s.event.sessionDuration,
      totalReps: s.event.totalReps,
      totalSets: s.event.totalSets,
      averageQuality: s.event.averageQuality,
      detectedView:
          s.event.exercise.isCurl &&
              s.event.detectedView != CurlCameraView.unknown
          ? s.event.detectedView
          : null,
      fatigueDetected: s.event.fatigueDetected,
      asymmetryDetected: s.event.asymmetryDetected,
      topErrors: topErrors,
    );
  }
}

class _InMemorySession {
  _InMemorySession({
    required this.id,
    required this.event,
    required this.startedAt,
    this.concentricDurations = const [],
  });
  final int id;
  final WorkoutCompletedEvent event;
  final DateTime startedAt;
  final List<Duration?> concentricDurations;
}

/// Back-compat shim for PR1 tests that observed inserts directly. PR2 prefers
/// `listSessions`/`getSession` — those are the real interface.
class RecordedInsert {
  const RecordedInsert({
    required this.id,
    required this.event,
    required this.startedAt,
  });
  final int id;
  final WorkoutCompletedEvent event;
  final DateTime startedAt;
}
