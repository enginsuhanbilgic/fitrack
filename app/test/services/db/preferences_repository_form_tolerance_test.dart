/// Tests for `getFormTolerancePercent` / `setFormTolerancePercent` on both
/// concrete implementations of `PreferencesRepository`.
///
/// Contract:
///   - Defaults to `kDefaultFormTolerancePercent` (0) on a fresh repository.
///   - Round-trips integer values via set/get.
///   - Clamps incoming writes to `[0, 100]` defensively.
///   - Garbage / unparseable values in the SQLite row fall back to default
///     rather than throwing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository – FormTolerancePercent', () {
    test('default is kDefaultFormTolerancePercent', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getFormTolerancePercent(), kDefaultFormTolerancePercent);
    });

    test('round-trips a value within range', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFormTolerancePercent(73);
      expect(await repo.getFormTolerancePercent(), 73);
    });

    test('clamps negative input to 0', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFormTolerancePercent(-50);
      expect(await repo.getFormTolerancePercent(), 0);
    });

    test('clamps > 100 input to 100', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFormTolerancePercent(250);
      expect(await repo.getFormTolerancePercent(), 100);
    });

    test('overwrite replaces previous value', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFormTolerancePercent(40);
      await repo.setFormTolerancePercent(85);
      expect(await repo.getFormTolerancePercent(), 85);
    });
  });

  group('SqlitePreferencesRepository – FormTolerancePercent', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is kDefaultFormTolerancePercent when no row exists', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getFormTolerancePercent(), kDefaultFormTolerancePercent);
    });

    test('round-trips a value within range', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFormTolerancePercent(60);
      expect(await repo.getFormTolerancePercent(), 60);
    });

    test('clamps negative input on write', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFormTolerancePercent(-30);
      expect(await repo.getFormTolerancePercent(), 0);
    });

    test('clamps > 100 input on write', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFormTolerancePercent(200);
      expect(await repo.getFormTolerancePercent(), 100);
    });

    test('overwrite replaces previous value', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFormTolerancePercent(25);
      await repo.setFormTolerancePercent(75);
      expect(await repo.getFormTolerancePercent(), 75);
    });

    test('non-numeric value in DB falls back to default', () async {
      await db.insert('preferences', {
        'key': 'form_tolerance_percent',
        'value': 'definitely_not_a_number',
      });
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getFormTolerancePercent(), kDefaultFormTolerancePercent);
    });

    test('out-of-range value in DB is clamped on read', () async {
      // Defensive read-time clamp: even if the DB was written outside the
      // setter (legacy import, hand-edit), readers see a clamped value.
      await db.insert('preferences', {
        'key': 'form_tolerance_percent',
        'value': '9999',
      });
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getFormTolerancePercent(), 100);
    });
  });
}
