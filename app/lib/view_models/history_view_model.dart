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
  HistoryViewModel({required this.repository, this.pageSize = 50});

  final SessionRepository repository;

  final int pageSize;

  ExerciseType? _filter; // null = all exercises merged
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  Object? _error;
  List<SessionSummary> _sessions = const <SessionSummary>[];

  /// Guards against `notifyListeners` after `dispose` when an in-flight
  /// `listSessions` resolves late.
  bool _disposed = false;

  ExerciseType? get filter => _filter;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  Object? get error => _error;
  List<SessionSummary> get sessions => _sessions;

  /// Load (or reload) the first page. Resets pagination state.
  Future<void> load() async {
    _offset = 0;
    _hasMore = true;
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      final list = await repository.listSessions(
        exercise: _filter,
        limit: pageSize,
        offset: _offset,
      );
      if (_disposed) return;
      _sessions = list;
      _hasMore = list.length == pageSize;
      _offset = list.length;
      _loading = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _loading = false;
      _safeNotify();
    }
  }

  /// Appends the next page. No-op if already loading or no more pages.
  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _disposed) return;
    _loadingMore = true;
    _safeNotify();
    try {
      final list = await repository.listSessions(
        exercise: _filter,
        limit: pageSize,
        offset: _offset,
      );
      if (_disposed) return;
      _sessions = [..._sessions, ...list];
      _hasMore = list.length == pageSize;
      _offset += list.length;
      _loadingMore = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _loadingMore = false;
      _safeNotify();
    }
  }

  /// Update the exercise filter and reload. Passing the same filter is a
  /// no-op (avoids a pointless DB round-trip). Resets pagination.
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
