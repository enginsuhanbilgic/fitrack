/// Lightweight in-memory telemetry log used for diagnostics.
///
/// Singleton, ring-buffered to [kTelemetryRingSize] entries. Newest first when
/// read. **Not persisted** in v1 — survives only the running process.
library;

import 'package:flutter/foundation.dart';

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

  /// Active ring-buffer cap. Defaults to [kTelemetryRingSize]. Call
  /// [setCap] at the start of a debug session and [resetCap] on dispose
  /// so the enlarged buffer is scoped exactly to the session lifetime.
  int _cap = kTelemetryRingSize;

  /// Expand the ring buffer for a debug session.
  void setCap(int cap) => _cap = cap;

  /// Restore the default cap after a debug session ends.
  void resetCap() => _cap = kTelemetryRingSize;

  /// Append an entry. Drops the oldest when over [_cap].
  ///
  /// In debug builds the entry is also mirrored to the IDE console so every
  /// telemetry event is visible without opening the in-app Diagnostics screen.
  /// The prefix `[FiTrack]` lets you filter the console with a single string.
  void log(String tag, String message, {Map<String, Object?>? data}) {
    final entry = TelemetryEntry(
      timestamp: DateTime.now(),
      tag: tag,
      message: message,
      data: data,
    );
    _entries.add(entry);
    if (_entries.length > _cap) {
      _entries.removeAt(0);
    }
    assert(() {
      final ts = entry.timestamp.toIso8601String();
      final dataStr = (data == null || data.isEmpty)
          ? ''
          : '\n          data: ${data.entries.map((e) => '${e.key}=${e.value}').join('  ')}';
      debugPrint('[FiTrack] $ts  $tag\n          $message$dataStr');
      return true;
    }());
  }

  /// Newest entries first. Returns an unmodifiable snapshot.
  List<TelemetryEntry> get entries => List.unmodifiable(_entries.reversed);

  /// Filter by tag prefix (`profile.` matches `profile.update`, `profile.outlier_rejected`, ...).
  List<TelemetryEntry> entriesWhere(bool Function(TelemetryEntry) test) =>
      List.unmodifiable(_entries.reversed.where(test));

  int get length => _entries.length;

  void clear() => _entries.clear();
}
