/// Persistence for completed workout sessions.
///
/// PR1 ships **interface only** plus an in-memory stub so [AppServices] has a
/// non-null field. PR2 lands [SqliteSessionRepository] and the full DTO surface
/// (`SessionSummary`, `SessionDetail`, `RepRow`); PR3 adds read paths for the
/// History screen; PR4 wires `recentConcentricDurations` to real data.
///
/// Keeping the interface stable from PR1 guarantees PR2's swap is additive:
/// `AppServicesScope` doesn't change shape, widget-tree plumbing stays intact.
library;

import '../../core/types.dart';
import '../../view_models/workout_view_model.dart' show WorkoutCompletedEvent;

abstract class SessionRepository {
  /// Writes one `sessions` row + N `reps` rows + M `form_errors` rows in a
  /// single transaction. Returns the new session id.
  ///
  /// PR1 stub: throws [UnimplementedError]. PR2: real transactional write.
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
  });

  /// Recent concentric durations for fatigue-baseline computation.
  ///
  /// Returns `<Duration>[]` until PR4 starts populating `reps.concentric_ms`.
  /// Call-sites MUST treat an empty list as "no baseline data" — never crash
  /// on empty.
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  });
}

/// In-memory double. Silently accepts writes and records them in order so
/// tests can assert on them without a SQLite dependency.
class InMemorySessionRepository implements SessionRepository {
  final List<RecordedInsert> _inserts = <RecordedInsert>[];
  int _nextId = 1;

  /// Test-only view. Caller must not mutate.
  List<RecordedInsert> get recordedInserts =>
      List<RecordedInsert>.unmodifiable(_inserts);

  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
  }) async {
    final id = _nextId++;
    _inserts.add(RecordedInsert(id: id, event: event, startedAt: startedAt));
    return id;
  }

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async {
    return const <Duration>[];
  }
}

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
