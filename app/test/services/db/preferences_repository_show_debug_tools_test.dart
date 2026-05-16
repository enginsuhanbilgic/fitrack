/// Tests for the `showDebugTools` preference.
///
/// Mirrors `preferences_repository_squat_debug_test.dart`, with the
/// crucial inversion: this pref **defaults to `true`** (visible) when
/// unset — the opposite of every other debug pref. That default is the
/// entire contract (a fresh install / developer build keeps the Home
/// debug cards; the developer flips it OFF before a real-user handoff),
/// so the "default is true" cases are the load-bearing assertions here.
///
/// Pure-Dart; `flutter_test` for assertions only. SQLite path uses the
/// in-memory ffi DB (`_test_db.dart`), no device.
library;

import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository – ShowDebugTools', () {
    test('default is TRUE (visible) when unset', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getShowDebugTools(), isTrue);
    });

    test('set false / get returns false', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setShowDebugTools(false);
      expect(await repo.getShowDebugTools(), isFalse);
    });

    test('set true after false returns true', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setShowDebugTools(false);
      await repo.setShowDebugTools(true);
      expect(await repo.getShowDebugTools(), isTrue);
    });
  });

  group('SqlitePreferencesRepository – ShowDebugTools', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is TRUE when no row exists', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getShowDebugTools(), isTrue);
    });

    test('round-trips false', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setShowDebugTools(false);
      expect(await repo.getShowDebugTools(), isFalse);
    });

    test('round-trips true after false', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setShowDebugTools(false);
      await repo.setShowDebugTools(true);
      expect(await repo.getShowDebugTools(), isTrue);
    });

    test('overwrite replaces previous value', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setShowDebugTools(true);
      await repo.setShowDebugTools(false);
      expect(await repo.getShowDebugTools(), isFalse);
    });
  });
}
