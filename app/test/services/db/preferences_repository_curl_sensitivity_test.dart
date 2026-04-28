import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository – CurlSensitivity', () {
    test('default is medium', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getCurlSensitivity(), CurlSensitivity.medium);
    });

    test('round-trips high', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setCurlSensitivity(CurlSensitivity.high);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.high);
    });

    test('round-trips back to medium after change', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setCurlSensitivity(CurlSensitivity.high);
      await repo.setCurlSensitivity(CurlSensitivity.medium);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.medium);
    });
  });

  group('SqlitePreferencesRepository – CurlSensitivity', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is medium when no row exists', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.medium);
    });

    test('round-trips high', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setCurlSensitivity(CurlSensitivity.high);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.high);
    });

    test('overwrite replaces previous value', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setCurlSensitivity(CurlSensitivity.medium);
      await repo.setCurlSensitivity(CurlSensitivity.high);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.high);
    });

    test('corrupt value in DB falls back to medium', () async {
      await db.insert('preferences', {
        'key': 'curl_sensitivity',
        'value': 'not_a_valid_enum_value',
      });
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getCurlSensitivity(), CurlSensitivity.medium);
    });
  });
}
