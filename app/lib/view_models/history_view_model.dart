/// ViewModel for the History screen.
///
/// Loads a page of [SessionSummary]s from [SessionRepository] and exposes
/// loading / error / sessions state to the widget. Filter is held on the VM
/// (not the widget) so swapping it triggers a reload without a widget rebuild
/// losing in-flight results.
///
/// Instantiated per-screen (matches the `WorkoutViewModel` convention); owned
/// by `_HistoryScreenState` and disposed when the screen pops.
library;

import 'package:flutter/foundation.dart';

import '../core/types.dart';
import '../services/db/session_dtos.dart';
import '../services/db/session_repository.dart';

class HistoryViewModel extends ChangeNotifier {
  HistoryViewModel({required this.repository, this.pageLimit = 100});

  final SessionRepository repository;

  /// Per plan: no pagination in v1. Single page of up to 100 sessions covers
  /// ~3 months of heavy use. Bump or swap for `ListView.builder` + load-more
  /// in a future PR if user data grows past this.
  final int pageLimit;

  ExerciseType? _filter; // null = all exercises merged
  bool _loading = false;
  Object? _error;
  List<SessionSummary> _sessions = const <SessionSummary>[];

  /// Guards against `notifyListeners` after `dispose` when an in-flight
  /// `listSessions` resolves late.
  bool _disposed = false;

  ExerciseType? get filter => _filter;
  bool get loading => _loading;
  Object? get error => _error;
  List<SessionSummary> get sessions => _sessions;

  /// Load (or reload with the current filter). Safe to call more than once;
  /// the most recent call always wins.
  Future<void> load() async {
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      final list = await repository.listSessions(
        exercise: _filter,
        limit: pageLimit,
      );
      if (_disposed) return;
      _sessions = list;
      _loading = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _loading = false;
      _safeNotify();
    }
  }

  /// Update the exercise filter and reload. Passing the same filter is a
  /// no-op (avoids a pointless DB round-trip).
  Future<void> setFilter(ExerciseType? next) async {
    if (next == _filter) return;
    _filter = next;
    await load();
  }

  /// Remove a session both from the DB and the in-memory list so the UI
  /// updates without a full reload. Deferred for v1 per plan (no delete UI),
  /// but exposing the VM-level method now keeps the repository read surface
  /// narrow — if PR4 or a follow-up adds a swipe-to-delete, the plumbing is
  /// one call away.
  Future<void> deleteSession(int id) async {
    await repository.deleteSession(id);
    if (_disposed) return;
    _sessions = _sessions.where((s) => s.id != id).toList(growable: false);
    _safeNotify();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
