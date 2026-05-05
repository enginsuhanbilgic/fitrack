/// ViewModel for the Home screen dashboard.
///
/// Loads the most recent session and summary stats from [SessionRepository],
/// exposing them to the dashboard cards (recent exercise, activity summary).
/// Instantiated per-screen; owned by `_HomeScreenState`.
library;

import 'package:flutter/foundation.dart';

import '../services/db/session_dtos.dart';
import '../services/db/session_repository.dart';

class HomeViewModel extends ChangeNotifier {
  HomeViewModel({required this.repository});

  final SessionRepository repository;

  /// The most recent session, or null if no sessions exist.
  SessionSummary? _lastSession;

  /// All sessions (cached on first load; used for activity summary stats).
  List<SessionSummary> _allSessions = const <SessionSummary>[];

  bool _loading = false;
  Object? _error;

  /// Guards against `notifyListeners` after `dispose`.
  bool _disposed = false;

  SessionSummary? get lastSession => _lastSession;
  List<SessionSummary> get allSessions => _allSessions;
  bool get loading => _loading;
  Object? get error => _error;

  /// Load dashboard data: most recent session + activity summary.
  Future<void> load() async {
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      // Fetch all sessions to compute summary stats and get the latest
      final list = await repository.listSessions(
        exercise: null, // all exercises
        limit: 100, // reasonable batch for dashboard
        offset: 0,
      );
      if (_disposed) return;
      _allSessions = list;
      _lastSession = list.isNotEmpty ? list.first : null;
      _loading = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _loading = false;
      _safeNotify();
    }
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
