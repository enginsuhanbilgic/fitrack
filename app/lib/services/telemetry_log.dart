/// Lightweight in-memory telemetry log used for diagnostics.
///
/// Singleton, ring-buffered to [kTelemetryRingSize] entries. Newest first when
/// read. **Not persisted** in v1 — survives only the running process.
library;

import '../core/constants.dart';

class TelemetryEntry {
  final DateTime timestamp;
  final String tag;
  final String message;
  final Map<String, Object?>? data;

  const TelemetryEntry({
    required this.timestamp,
    required this.tag,
    required this.message,
    this.data,
  });

  @override
  String toString() {
    final t = timestamp.toIso8601String();
    final d = data == null || data!.isEmpty ? '' : ' ${data.toString()}';
    return '[$t] $tag: $message$d';
  }
}

class TelemetryLog {
  TelemetryLog._();
  static final TelemetryLog instance = TelemetryLog._();

  final List<TelemetryEntry> _entries = <TelemetryEntry>[];

  /// Append an entry. Drops the oldest when over [kTelemetryRingSize].
  void log(String tag, String message, {Map<String, Object?>? data}) {
    _entries.add(
      TelemetryEntry(
        timestamp: DateTime.now(),
        tag: tag,
        message: message,
        data: data,
      ),
    );
    if (_entries.length > kTelemetryRingSize) {
      _entries.removeAt(0);
    }
  }

  /// Newest entries first. Returns an unmodifiable snapshot.
  List<TelemetryEntry> get entries => List.unmodifiable(_entries.reversed);

  /// Filter by tag prefix (`profile.` matches `profile.update`, `profile.outlier_rejected`, ...).
  List<TelemetryEntry> entriesWhere(bool Function(TelemetryEntry) test) =>
      List.unmodifiable(_entries.reversed.where(test));

  int get length => _entries.length;

  void clear() => _entries.clear();
}
