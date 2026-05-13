/// Pure-Dart aggregations used by the Dashboard ring + weekly volume bars
/// and the Profile tab stats card. Every function in this file is a pure
/// function of `List<SessionSummary>` — no DB access, no time-zone math
/// beyond `DateTime.now()`. This makes them trivially unit-testable and
/// safe to call from any layer.
///
/// "Strain / Recovery / Output" are interpretable proxies, NOT clones of
/// the Whoop metrics of the same name. Each metric has the formula
/// inlined as a doc-comment so a future analyst can re-derive it from
/// the session table without re-reading this file.
library;

import '../services/db/session_dtos.dart';

/// Result bundle returned by [computeDashboardMetrics] — keeps the call
/// site short and avoids re-iterating the session list per metric.
class DashboardMetrics {
  const DashboardMetrics({
    required this.strain,
    required this.recovery,
    required this.output,
    required this.weeklyBars,
    required this.totalSessions,
    required this.totalHours,
    required this.personalRecords,
    required this.weeklyRepCount,
  });

  /// 0..21 — Whoop's display range, but our formula. See [computeStrain].
  final double strain;

  /// 0..1 — see [computeRecovery].
  final double recovery;

  /// 0..1 — see [computeOutput].
  final double output;

  /// Seven values, one per weekday. Index 0 = Monday, index 6 = Sunday.
  /// Each value is the rep count for that day in the current ISO week.
  final List<int> weeklyBars;

  /// Total completed sessions all-time.
  final int totalSessions;

  /// Total training hours all-time, rounded to 1 decimal at format time.
  final double totalHours;

  /// Number of distinct exercise types the user has completed at least
  /// one session of. Used as a proxy "PRs" stat on the Profile tab — a
  /// real PR system needs a separate `personal_records` table (deferred).
  final int personalRecords;

  /// Total reps in the current ISO week. Drives the headline number on
  /// the weekly-volume card.
  final int weeklyRepCount;
}

/// One-pass entry point: compute every dashboard metric from a single scan.
DashboardMetrics computeDashboardMetrics(
  List<SessionSummary> sessions, {
  DateTime? now,
}) {
  final ts = now ?? DateTime.now();
  final last7 = sessionsInLastNDays(sessions, 7, now: ts);
  return DashboardMetrics(
    strain: computeStrain(last7),
    recovery: computeRecovery(sessions, now: ts),
    output: computeOutput(last7),
    weeklyBars: computeWeeklyBars(sessions, now: ts),
    totalSessions: sessions.length,
    totalHours: computeTotalHours(sessions),
    personalRecords: countDistinctExercises(sessions),
    weeklyRepCount: last7.fold<int>(0, (a, s) => a + s.totalReps),
  );
}

/// Sessions whose `startedAt` falls within `[now − days, now]`. The window
/// is inclusive at both ends.
List<SessionSummary> sessionsInLastNDays(
  List<SessionSummary> sessions,
  int days, {
  DateTime? now,
}) {
  final ts = now ?? DateTime.now();
  final cutoff = ts.subtract(Duration(days: days));
  return sessions
      .where((s) => !s.startedAt.isBefore(cutoff))
      .toList(growable: false);
}

/// **Strain** proxy: sum of `(reps × duration_minutes)` over the last 7
/// days, normalized so 50 rep-minutes ≈ 1 strain unit, then clamped to
/// the 0..21 display range Whoop popularized.
///
/// Rationale: rep count alone misses density (60 reps in 5 min ≠ 60 reps
/// in 30 min), and duration alone misses intensity. The product captures
/// both with one cheap formula. The 50-rep-minute scaling is calibrated
/// so a typical 30-rep, 4-minute session reads ≈ 2.4 (light), and a
/// 100-rep, 15-minute session reads ≈ 30 → clamped to 21 (max).
double computeStrain(List<SessionSummary> last7d) {
  final raw = last7d.fold<double>(
    0.0,
    (acc, s) => acc + s.totalReps * (s.duration.inSeconds / 60.0),
  );
  return (raw / 50.0).clamp(0.0, 21.0);
}

/// **Recovery** proxy: days since the most recent session that flagged
/// `fatigueDetected = true`, normalized to a 0..1 scale where 1.0 means
/// "fully recovered (≥7 days fatigue-free)" and 0.0 means "fatigued today".
///
/// When the user has no fatigue-flagged sessions ever (most common case
/// for casual users), recovery is 1.0 — we don't penalize the absence of
/// data.
double computeRecovery(List<SessionSummary> all, {DateTime? now}) {
  final ts = now ?? DateTime.now();
  SessionSummary? lastFatigue;
  for (final s in all) {
    if (s.fatigueDetected) {
      if (lastFatigue == null || s.startedAt.isAfter(lastFatigue.startedAt)) {
        lastFatigue = s;
      }
    }
  }
  if (lastFatigue == null) return 1.0;
  final daysSince = ts.difference(lastFatigue.startedAt).inHours / 24.0;
  return (daysSince / 7.0).clamp(0.0, 1.0);
}

/// **Output** proxy: mean `averageQuality` across last-7-day sessions.
/// `averageQuality` is already 0..1 (per-rep quality is the FSM's form
/// score), so we just average and return — UI multiplies by 100 for the
/// percentage display. Returns 0.0 when no sessions exist in the window
/// (rather than NaN).
double computeOutput(List<SessionSummary> last7d) {
  if (last7d.isEmpty) return 0.0;
  double sum = 0.0;
  int n = 0;
  for (final s in last7d) {
    final q = s.averageQuality;
    if (q == null) continue;
    sum += q;
    n++;
  }
  if (n == 0) return 0.0;
  return sum / n;
}

/// Seven rep-count buckets, indexed [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
/// for the **current ISO week** (Monday-based). Sessions outside the
/// current week are ignored. Returns all zeros for a fresh install.
///
/// We use ISO weeks because Dart's `DateTime.weekday` is already 1=Mon..7=Sun,
/// and most fitness apps the user is comparing against (Strava, Apple
/// Fitness) also Monday-anchor their weekly bars.
List<int> computeWeeklyBars(List<SessionSummary> sessions, {DateTime? now}) {
  final ts = now ?? DateTime.now();
  final monday = DateTime(
    ts.year,
    ts.month,
    ts.day,
  ).subtract(Duration(days: ts.weekday - 1));
  final nextMonday = monday.add(const Duration(days: 7));
  final bars = List<int>.filled(7, 0);
  for (final s in sessions) {
    if (s.startedAt.isBefore(monday)) continue;
    if (!s.startedAt.isBefore(nextMonday)) continue;
    final idx = s.startedAt.weekday - 1; // Monday=0..Sunday=6
    bars[idx] += s.totalReps;
  }
  return bars;
}

/// Total training duration across all sessions, expressed in fractional
/// hours. Caller formats — typically `total.toStringAsFixed(1)`.
double computeTotalHours(List<SessionSummary> sessions) {
  final secs = sessions.fold<int>(0, (a, s) => a + s.duration.inSeconds);
  return secs / 3600.0;
}

/// Count of distinct exercise types the user has at least one completed
/// session of. Used as a stand-in for "PRs" on the Profile tab until a
/// proper personal-records system ships.
int countDistinctExercises(List<SessionSummary> sessions) {
  final s = <String>{};
  for (final session in sessions) {
    s.add(session.exercise.name);
  }
  return s.length;
}
