/// Pure-Dart formatter for the `pushup.rep` telemetry line.
///
/// Lives outside `workout_view_model.dart` so the format contract can be
/// unit-tested with `package:test` directly, without paying for the
/// `package:flutter_test` widget-test surface that the project explicitly
/// forbids (CLAUDE.md "Test Writing Hard Rules"). The view-model's
/// `_handlePushUpRepCommit` is a thin caller — it tracks the per-session
/// monotonic rep counter and hands the formatted string to
/// `TelemetryLog.instance.log`.
///
/// Output shape (always-on, single line):
///
///     rep=<n> min_elbow=<f|null> max_elbow=<f|null>
///
/// Both angle fields use `toStringAsFixed(2)` precision when present —
/// matches squat's `min_knee` / `max_knee` emission. `null` is emitted as
/// the literal string `"null"` (not omitted) so the Python parser regex
/// can stay anchored on a fixed token order without optional groups.
String formatPushUpRepLine({
  required int repIndex,
  required double? minElbowAngle,
  required double? maxElbowAngle,
}) =>
    'rep=$repIndex '
    'min_elbow=${minElbowAngle?.toStringAsFixed(2) ?? "null"} '
    'max_elbow=${maxElbowAngle?.toStringAsFixed(2) ?? "null"}';
