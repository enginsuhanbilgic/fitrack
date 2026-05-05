import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:fitrack/services/db/session_repository.dart';
import 'package:fitrack/view_models/history_view_model.dart';
import 'package:fitrack/view_models/workout_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a minimal curl completion event. Keeps test fixtures small — the
/// history VM only cares about the exercise + rep count + timestamp.
WorkoutCompletedEvent _curlEvent({int reps = 2}) {
  return WorkoutCompletedEvent(
    exercise: ExerciseType.bicepsCurl,
    totalReps: reps,
    totalSets: 1,
    sessionDuration: const Duration(seconds: 30),
    averageQuality: 0.85,
    detectedView: CurlCameraView.front,
    repQualities: List<double>.generate(reps, (_) => 0.85),
    fatigueDetected: false,
    asymmetryDetected: false,
    eccentricTooFastCount: 0,
    errorsTriggered: const {},
    curlRepRecords: const [],
    curlBucketSummaries: const [],
  );
}

WorkoutCompletedEvent _squatEvent({int reps = 3}) {
  return WorkoutCompletedEvent(
    exercise: ExerciseType.squat,
    totalReps: reps,
    totalSets: 1,
    sessionDuration: const Duration(seconds: 45),
    averageQuality: 0.78,
    detectedView: CurlCameraView.unknown,
    repQualities: List<double>.generate(reps, (_) => 0.78),
    fatigueDetected: false,
    asymmetryDetected: false,
    eccentricTooFastCount: 0,
    errorsTriggered: const {},
    curlRepRecords: const [],
    curlBucketSummaries: const [],
  );
}

/// Repo that throws on listSessions — surfaces the error path.
class _ThrowingRepo implements SessionRepository {
  @override
  Future<int> insertCompletedSession(
    WorkoutCompletedEvent event, {
    required DateTime startedAt,
    List<Duration?> concentricDurations = const [],
    List<double?> dtwSimilarities = const [],
  }) async => 0;

  @override
  Future<List<SessionSummary>> listSessions({
    ExerciseType? exercise,
    int limit = 100,
    int offset = 0,
  }) async {
    throw StateError('simulated load failure');
  }

  @override
  Future<SessionDetail?> getSession(int sessionId) async => null;

  @override
  Future<void> deleteSession(int sessionId) async {}

  @override
  Future<List<Duration>> recentConcentricDurations({
    required ExerciseType exercise,
    required Duration window,
    int limitReps = 200,
  }) async => const [];
}

void main() {
  group('HistoryViewModel.load', () {
    test('empty repo → sessions empty, loading clears, error null', () async {
      final vm = HistoryViewModel(repository: InMemorySessionRepository());
      await vm.load();
      expect(vm.sessions, isEmpty);
      expect(vm.loading, isFalse);
      expect(vm.error, isNull);
      vm.dispose();
    });

    test('populated repo → sessions newest-first', () async {
      final repo = InMemorySessionRepository();
      await repo.insertCompletedSession(
        _curlEvent(reps: 1),
        startedAt: DateTime(2026, 4, 20),
      );
      await repo.insertCompletedSession(
        _curlEvent(reps: 2),
        startedAt: DateTime(2026, 4, 25),
      );
      await repo.insertCompletedSession(
        _curlEvent(reps: 3),
        startedAt: DateTime(2026, 4, 22),
      );

      final vm = HistoryViewModel(repository: repo);
      await vm.load();

      expect(vm.sessions.map((s) => s.totalReps).toList(), [2, 3, 1]);
      vm.dispose();
    });

    test('surfaces error when repository throws', () async {
      final vm = HistoryViewModel(repository: _ThrowingRepo());
      await vm.load();
      expect(vm.error, isNotNull);
      expect(vm.loading, isFalse);
      expect(vm.sessions, isEmpty);
      vm.dispose();
    });

    test('notifies listeners twice: loading=true, then loaded', () async {
      final vm = HistoryViewModel(repository: InMemorySessionRepository());
      final states = <bool>[];
      vm.addListener(() => states.add(vm.loading));
      await vm.load();
      // At minimum we expect a transition through loading=true then back to
      // false. Exact count can vary with implementation details; the contract
      // is "at least one notify while loading AND at least one after it
      // cleared."
      expect(states.any((l) => l == true), isTrue);
      expect(states.last, isFalse);
      vm.dispose();
    });
  });

  group('HistoryViewModel.setFilter', () {
    test('same filter is a no-op (does not reload)', () async {
      final repo = InMemorySessionRepository();
      final vm = HistoryViewModel(repository: repo);
      await vm.load();

      var notifyCount = 0;
      vm.addListener(() => notifyCount++);
      await vm.setFilter(null); // same as default
      expect(notifyCount, 0, reason: 'no reload should fire');
      vm.dispose();
    });

    test('new filter reloads with the exercise filter applied', () async {
      final repo = InMemorySessionRepository();
      await repo.insertCompletedSession(
        _curlEvent(reps: 5),
        startedAt: DateTime(2026, 4, 25),
      );
      await repo.insertCompletedSession(
        _squatEvent(reps: 8),
        startedAt: DateTime(2026, 4, 25),
      );

      final vm = HistoryViewModel(repository: repo);
      await vm.load();
      expect(vm.sessions, hasLength(2));

      await vm.setFilter(ExerciseType.bicepsCurl);
      expect(vm.filter, ExerciseType.bicepsCurl);
      expect(vm.sessions, hasLength(1));
      expect(vm.sessions.first.exercise, ExerciseType.bicepsCurl);

      await vm.setFilter(null);
      expect(vm.sessions, hasLength(2));
      vm.dispose();
    });
  });

  group('HistoryViewModel.deleteSession', () {
    test('removes session from the in-memory list and the repo', () async {
      final repo = InMemorySessionRepository();
      final id = await repo.insertCompletedSession(
        _curlEvent(reps: 1),
        startedAt: DateTime.now(),
      );
      await repo.insertCompletedSession(
        _curlEvent(reps: 2),
        startedAt: DateTime.now(),
      );

      final vm = HistoryViewModel(repository: repo);
      await vm.load();
      expect(vm.sessions, hasLength(2));

      await vm.deleteSession(id);
      expect(vm.sessions, hasLength(1));
      expect(await repo.getSession(id), isNull);
      vm.dispose();
    });
  });

  group('HistoryViewModel.loadMore (pagination)', () {
    /// Seeds [repo] with [count] curl sessions and returns the inserted ids.
    Future<void> seed(InMemorySessionRepository repo, int count) async {
      for (var i = 0; i < count; i++) {
        await repo.insertCompletedSession(
          _curlEvent(reps: i + 1),
          startedAt: DateTime(2026, 1, 1).add(Duration(days: i)),
        );
      }
    }

    test('120 sessions load in two pages of 50 + one page of 20', () async {
      final repo = InMemorySessionRepository();
      await seed(repo, 120);

      final vm = HistoryViewModel(repository: repo, pageSize: 50);
      await vm.load();
      expect(vm.sessions, hasLength(50));
      expect(vm.hasMore, isTrue);

      await vm.loadMore();
      expect(vm.sessions, hasLength(100));
      expect(vm.hasMore, isTrue);

      await vm.loadMore();
      expect(vm.sessions, hasLength(120));
      expect(vm.hasMore, isFalse);

      vm.dispose();
    });

    test('loadMore is a no-op after reaching end', () async {
      final repo = InMemorySessionRepository();
      await seed(repo, 10);

      final vm = HistoryViewModel(repository: repo, pageSize: 50);
      await vm.load();
      expect(vm.sessions, hasLength(10));
      expect(vm.hasMore, isFalse);

      var notifyCount = 0;
      vm.addListener(() => notifyCount++);
      await vm.loadMore();
      expect(notifyCount, 0, reason: 'no-op should not notify');
      expect(vm.sessions, hasLength(10));
      vm.dispose();
    });

    test('pull-to-refresh (load) resets to first page', () async {
      final repo = InMemorySessionRepository();
      await seed(repo, 80);

      final vm = HistoryViewModel(repository: repo, pageSize: 50);
      await vm.load();
      await vm.loadMore();
      expect(vm.sessions, hasLength(80));

      // Simulate pull-to-refresh.
      await vm.load();
      expect(vm.sessions, hasLength(50));
      expect(vm.hasMore, isTrue);
      vm.dispose();
    });

    test('filter change resets pagination', () async {
      final repo = InMemorySessionRepository();
      await seed(repo, 60); // curl sessions
      for (var i = 0; i < 5; i++) {
        await repo.insertCompletedSession(
          _squatEvent(reps: i + 1),
          startedAt: DateTime(2026, 6, 1).add(Duration(days: i)),
        );
      }

      final vm = HistoryViewModel(repository: repo, pageSize: 50);
      await vm.load();
      expect(vm.sessions, hasLength(50));

      await vm.setFilter(ExerciseType.squat);
      expect(vm.sessions, hasLength(5));
      expect(vm.hasMore, isFalse);
      vm.dispose();
    });
  });

  group('HistoryViewModel.dispose', () {
    test(
      'disposing during load does not throw when load resolves late',
      () async {
        final vm = HistoryViewModel(repository: InMemorySessionRepository());
        // Start the load, then dispose before awaiting.
        final future = vm.load();
        vm.dispose();
        // Future resolves against the disposed VM; internal guard must swallow.
        await future;
        // No assertion beyond "did not throw" — verified by reaching this line.
      },
    );
  });
}
