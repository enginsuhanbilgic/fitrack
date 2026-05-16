/// Ring-buffer tests for the `TelemetryLog` singleton.
///
/// The buffer caps degraded sessions so a per-frame warning at ~15 fps
/// can't exhaust memory. These tests pin the eviction boundary and the
/// newest-first read order via the public API only (`log` / `entries` /
/// `length` / `setCap` / `resetCap` / `clear`) — `_entries` is private.
///
/// `TelemetryLog` is a process-wide singleton with mutable state, so
/// every test restores it in `tearDown` (clear + resetCap) to keep the
/// suite order-independent.
///
/// Pure-Dart — `flutter_test` only for `group` / `test` / `expect`
/// (no `pumpWidget`). Satisfies the "no widget tests" hard rule.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/services/telemetry_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final log = TelemetryLog.instance;

  tearDown(() {
    log
      ..clear()
      ..resetCap();
  });

  group('TelemetryLog ring buffer', () {
    test('default cap is kTelemetryRingSize', () {
      // Sanity: the production default the app relies on.
      expect(kTelemetryRingSize, 500);
    });

    test('holds up to cap entries without eviction', () {
      log.setCap(5);
      for (var i = 0; i < 5; i++) {
        log.log('t$i', 'm$i');
      }
      expect(log.length, 5);
      // Newest-first: most recent log is entries.first.
      expect(log.entries.first.tag, 't4');
      expect(log.entries.last.tag, 't0');
    });

    test('cap+1 drops the OLDEST, keeps newest-first order', () {
      log.setCap(3);
      log
        ..log('a', '0')
        ..log('b', '1')
        ..log('c', '2')
        ..log('d', '3'); // 4th → 'a' evicted

      expect(log.length, 3);
      final tags = log.entries.map((e) => e.tag).toList();
      // Newest-first, oldest ('a') gone.
      expect(tags, ['d', 'c', 'b']);
    });

    test('sustained overflow stays pinned at cap', () {
      log.setCap(2);
      for (var i = 0; i < 50; i++) {
        log.log('k', 'v$i');
      }
      expect(log.length, 2);
      expect(log.entries.first.message, 'v49');
      expect(log.entries.last.message, 'v48');
    });

    test('entries getter is an unmodifiable snapshot', () {
      log.log('x', 'y');
      final snap = log.entries;
      expect(() => snap.clear(), throwsUnsupportedError);
    });

    test('clear empties the buffer', () {
      log
        ..log('a', '1')
        ..log('b', '2');
      expect(log.length, 2);
      log.clear();
      expect(log.length, 0);
      expect(log.entries, isEmpty);
    });

    test('resetCap restores the default cap', () {
      log.setCap(1);
      log
        ..log('a', '1')
        ..log('b', '2'); // capped at 1
      expect(log.length, 1);
      log
        ..clear()
        ..resetCap();
      // Back to 500-wide: 3 entries all retained.
      log
        ..log('a', '1')
        ..log('b', '2')
        ..log('c', '3');
      expect(log.length, 3);
    });

    test('entriesWhere filters and stays newest-first', () {
      log
        ..log('profile.update', '1')
        ..log('pose.warn', '2')
        ..log('profile.outlier', '3');
      final profile = log.entriesWhere((e) => e.tag.startsWith('profile.'));
      expect(profile.map((e) => e.tag).toList(), [
        'profile.outlier',
        'profile.update',
      ]);
    });
  });
}
