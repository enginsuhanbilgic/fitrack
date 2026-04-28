import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository – SquatDebugSession', () {
    test('default is false', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getSquatDebugSession(), isFalse);
    });

    test('set true / get returns true', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setSquatDebugSession(true);
      expect(await repo.getSquatDebugSession(), isTrue);
    });

    test('set false after true returns false', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setSquatDebugSession(true);
      await repo.setSquatDebugSession(false);
      expect(await repo.getSquatDebugSession(), isFalse);
    });
  });

  group('SqlitePreferencesRepository – SquatDebugSession', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is false when no row exists', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getSquatDebugSession(), isFalse);
    });

    test('round-trips true', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setSquatDebugSession(true);
      expect(await repo.getSquatDebugSession(), isTrue);
    });

    test('round-trips false after true', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setSquatDebugSession(true);
      await repo.setSquatDebugSession(false);
      expect(await repo.getSquatDebugSession(), isFalse);
    });

    test('overwrite replaces previous value', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setSquatDebugSession(false);
      await repo.setSquatDebugSession(true);
      expect(await repo.getSquatDebugSession(), isTrue);
    });
  });
}
