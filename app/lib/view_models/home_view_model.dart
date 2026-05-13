/// ViewModel for the Home screen dashboard.
///
/// Loads the most recent session, aggregated dashboard metrics, and the
/// local user profile from the database, exposing them to every Home tab
/// (Dashboard, Profile, History card). Instantiated per-screen; owned by
/// `_HomeScreenState`.
library;

import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import '../services/db/session_dtos.dart';
import '../services/db/session_repository.dart';
import '../services/db/user_profile_repository.dart';
import '../utils/dashboard_aggregates.dart';

class HomeViewModel extends ChangeNotifier {
  HomeViewModel({
    required this.repository,
    required this.userProfileRepository,
  });

  final SessionRepository repository;
  final UserProfileRepository userProfileRepository;

  /// The most recent session, or null if no sessions exist.
  SessionSummary? _lastSession;

  /// All sessions (cached on first load; used for activity summary stats).
  List<SessionSummary> _allSessions = const <SessionSummary>[];

  /// Local user profile, or null when the user has not yet completed
  /// Edit Profile. UI uses null to render the "Set up your profile" CTA.
  UserProfile? _userProfile;

  /// Memoized aggregates — recomputed on every successful [load]. Cheap
  /// (single pass over `_allSessions`) but keeping it cached avoids
  /// per-build recomputation in widgets that read multiple metrics.
  DashboardMetrics _metrics = const DashboardMetrics(
    strain: 0.0,
    recovery: 1.0,
    output: 0.0,
    weeklyBars: <int>[0, 0, 0, 0, 0, 0, 0],
    totalSessions: 0,
    totalHours: 0.0,
    personalRecords: 0,
    weeklyRepCount: 0,
  );

  bool _loading = false;
  Object? _error;

  /// Guards against `notifyListeners` after `dispose`.
  bool _disposed = false;

  SessionSummary? get lastSession => _lastSession;
  List<SessionSummary> get allSessions => _allSessions;
  UserProfile? get userProfile => _userProfile;
  DashboardMetrics get metrics => _metrics;
  bool get loading => _loading;
  Object? get error => _error;

  /// Load dashboard data: most recent session, all sessions for aggregates,
  /// and the local user profile. Errors on either fetch fail the whole
  /// load — we'd rather show an error banner than a half-rendered dashboard.
  Future<void> load() async {
    _loading = true;
    _error = null;
    _safeNotify();
    try {
      // Fan out the two independent reads. The DB serializes them under
      // the hood, but this is the place where parallel cloud fetches
      // would slot in cleanly later.
      final futureSessions = repository.listSessions(
        exercise: null,
        limit: 100,
        offset: 0,
      );
      final futureProfile = userProfileRepository.load();
      final list = await futureSessions;
      final profile = await futureProfile;
      if (_disposed) return;
      _allSessions = list;
      _lastSession = list.isNotEmpty ? list.first : null;
      _userProfile = profile;
      _metrics = computeDashboardMetrics(list);
      _loading = false;
      _safeNotify();
    } catch (e) {
      if (_disposed) return;
      _error = e;
      _loading = false;
      _safeNotify();
    }
  }

  /// Refresh just the user profile after Edit Profile saves. Avoids the
  /// session re-fetch since nothing about workouts changed.
  Future<void> refreshUserProfile() async {
    try {
      final profile = await userProfileRepository.load();
      if (_disposed) return;
      _userProfile = profile;
      _safeNotify();
    } catch (_) {
      // Profile refresh failures are silent — the previous profile stays
      // visible. The next full `load()` will surface any persistent issue.
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
