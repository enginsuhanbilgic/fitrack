/// Exports persisted sessions to two CSV files (`sessions.csv` + `reps.csv`)
/// linked by `session_id`. Pure-Dart — no Flutter imports — so the format
/// logic can be unit-tested without a temp filesystem.
///
/// File-writing convenience method [exportToTempDir] writes both files to the
/// platform temp directory and returns the paths; callers (Settings UI) then
/// hand them to `share_plus`.
///
/// CSV escaping follows RFC 4180: fields containing commas, quotes, or
/// newlines are wrapped in double quotes; embedded quotes are doubled.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db/session_dtos.dart';
import 'db/session_repository.dart';

/// File paths produced by an export run.
class ExportResult {
  const ExportResult({
    required this.sessionsCsv,
    required this.repsCsv,
    required this.sessionCount,
    required this.repCount,
  });

  final String sessionsCsv;
  final String repsCsv;
  final int sessionCount;
  final int repCount;
}

class SessionExporter {
  SessionExporter({required this.repository});

  final SessionRepository repository;

  /// Generate the `sessions.csv` content as a string. One row per session.
  /// Header includes every column a Strava/Apple-Fitness style consumer
  /// would expect: id, exercise, started_at (ISO8601 UTC), duration_seconds,
  /// total_reps, total_sets, average_quality, detected_view, fatigue_detected,
  /// asymmetry_detected.
  static String sessionsCsv(List<SessionSummary> sessions) {
    final buf = StringBuffer();
    buf.writeln(
      'id,exercise,started_at,duration_seconds,total_reps,total_sets,'
      'average_quality,detected_view,fatigue_detected,asymmetry_detected',
    );
    for (final s in sessions) {
      buf.writeln(
        [
          s.id,
          _csvField(s.exercise.name),
          _csvField(s.startedAt.toUtc().toIso8601String()),
          s.duration.inSeconds,
          s.totalReps,
          s.totalSets,
          _csvField(s.averageQuality?.toStringAsFixed(4) ?? ''),
          _csvField(s.detectedView?.name ?? ''),
          s.fatigueDetected ? 1 : 0,
          s.asymmetryDetected ? 1 : 0,
        ].join(','),
      );
    }
    return buf.toString();
  }

  /// Generate the `reps.csv` content as a string. One row per rep across all
  /// sessions; `session_id` joins back to `sessions.csv`.
  ///
  /// Squat-specific columns (`squat_lean_deg` / `squat_knee_shift_ratio` /
  /// `squat_heel_lift_ratio` / `squat_variant`) are populated only for squat
  /// reps written by schema-v3 builds. Empty for curl, push-up, and
  /// pre-rebuild squat rows. Enables the telemetry-driven retune workflow
  /// in `docs/squat/SQUAT_MASTER_SPEC.md §10.3` — open in a spreadsheet,
  /// pivot by `squat_variant`, compute the per-threshold percentile.
  ///
  /// `form_errors` is a single semicolon-separated TEXT field per rep — we
  /// don't have a per-rep form-errors mapping in the schema (form errors
  /// aggregate at the session level), so this column is always empty in the
  /// current export. Reserved shape so consumers don't have to re-parse the
  /// header when per-rep form errors land in a future schema bump.
  static String repsCsv(
    List<({SessionSummary session, SessionDetail detail})> all,
  ) {
    final buf = StringBuffer();
    buf.writeln(
      'session_id,rep_index,quality,min_angle,max_angle,side,view,'
      'threshold_source,bucket_updated,rejected_outlier,concentric_ms,'
      'squat_lean_deg,squat_knee_shift_ratio,squat_heel_lift_ratio,'
      'squat_variant,'
      'biceps_lean_deg,biceps_shoulder_drift_ratio,biceps_elbow_drift_ratio,'
      'biceps_back_lean_deg,biceps_elbow_drift_signed,'
      'form_errors',
    );
    for (final entry in all) {
      final sessionId = entry.session.id;
      for (final r in entry.detail.reps) {
        buf.writeln(
          [
            sessionId,
            r.repIndex,
            _csvField(r.quality?.toStringAsFixed(4) ?? ''),
            _csvField(r.minAngle?.toStringAsFixed(2) ?? ''),
            _csvField(r.maxAngle?.toStringAsFixed(2) ?? ''),
            _csvField(r.side?.name ?? ''),
            _csvField(r.view?.name ?? ''),
            _csvField(r.source?.name ?? ''),
            r.bucketUpdated == null ? '' : (r.bucketUpdated! ? 1 : 0),
            r.rejectedOutlier == null ? '' : (r.rejectedOutlier! ? 1 : 0),
            r.concentricMs == null ? '' : '${r.concentricMs}',
            _csvField(r.squatLeanDeg?.toStringAsFixed(2) ?? ''),
            _csvField(r.squatKneeShiftRatio?.toStringAsFixed(4) ?? ''),
            _csvField(r.squatHeelLiftRatio?.toStringAsFixed(4) ?? ''),
            _csvField(r.squatVariant?.name ?? ''),
            _csvField(r.bicepsLeanDeg?.toStringAsFixed(2) ?? ''),
            _csvField(r.bicepsShoulderDriftRatio?.toStringAsFixed(4) ?? ''),
            _csvField(r.bicepsElbowDriftRatio?.toStringAsFixed(4) ?? ''),
            _csvField(r.bicepsBackLeanDeg?.toStringAsFixed(2) ?? ''),
            _csvField(r.bicepsElbowDriftSigned?.toStringAsFixed(4) ?? ''),
            // form_errors reserved column — empty until per-rep errors persist.
            '',
          ].join(','),
        );
      }
    }
    return buf.toString();
  }

  /// Read every session, build both CSVs, write them to the platform temp
  /// directory, and return the paths so the caller can hand them to a share
  /// sheet. Caller is responsible for cleanup; the OS will eventually purge
  /// the temp dir on its own schedule.
  Future<ExportResult> exportToTempDir({Directory? tmpOverride}) async {
    final summaries = await repository.listSessions(
      // No exercise filter — export everything.
      limit:
          100000, // effectively unbounded; matches the typical user's lifetime
    );
    final details = <({SessionSummary session, SessionDetail detail})>[];
    var repCount = 0;
    for (final s in summaries) {
      final d = await repository.getSession(s.id);
      if (d == null) continue;
      details.add((session: s, detail: d));
      repCount += d.reps.length;
    }

    final dir = tmpOverride ?? await getTemporaryDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final sessionsFile = File('${dir.path}/fitrack_sessions_$stamp.csv');
    final repsFile = File('${dir.path}/fitrack_reps_$stamp.csv');

    await sessionsFile.writeAsString(sessionsCsv(summaries));
    await repsFile.writeAsString(repsCsv(details));

    return ExportResult(
      sessionsCsv: sessionsFile.path,
      repsCsv: repsFile.path,
      sessionCount: summaries.length,
      repCount: repCount,
    );
  }

  /// RFC 4180-conformant escaping. Wraps in double quotes when the field
  /// contains a comma, quote, CR, or LF; doubles embedded quotes.
  static String _csvField(String raw) {
    final needsQuoting =
        raw.contains(',') ||
        raw.contains('"') ||
        raw.contains('\n') ||
        raw.contains('\r');
    if (!needsQuoting) return raw;
    final escaped = raw.replaceAll('"', '""');
    return '"$escaped"';
  }
}
