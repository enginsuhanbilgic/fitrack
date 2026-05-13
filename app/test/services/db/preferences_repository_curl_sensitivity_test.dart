import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/preferences_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('InMemoryPreferencesRepository – FeedbackSensitivity', () {
    test('default is medium', () async {
      final repo = InMemoryPreferencesRepository();
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.medium);
    });

    test('round-trips high', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFeedbackSensitivity(FeedbackSensitivity.high);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.high);
    });

    test('round-trips back to medium after change', () async {
      final repo = InMemoryPreferencesRepository();
      await repo.setFeedbackSensitivity(FeedbackSensitivity.high);
      await repo.setFeedbackSensitivity(FeedbackSensitivity.medium);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.medium);
    });
  });

  group('SqlitePreferencesRepository – FeedbackSensitivity', () {
    late Database db;

    setUp(() async {
      db = await openTestDb();
    });

    tearDown(() async {
      await db.close();
    });

    test('default is medium when no row exists', () async {
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.medium);
    });

    test('round-trips high', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFeedbackSensitivity(FeedbackSensitivity.high);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.high);
    });

    test('overwrite replaces previous value', () async {
      final repo = SqlitePreferencesRepository(db);
      await repo.setFeedbackSensitivity(FeedbackSensitivity.medium);
      await repo.setFeedbackSensitivity(FeedbackSensitivity.high);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.high);
    });

    test('corrupt value in DB falls back to medium', () async {
      await db.insert('preferences', {
        'key': 'feedback_sensitivity',
        'value': 'not_a_valid_enum_value',
      });
      final repo = SqlitePreferencesRepository(db);
      expect(await repo.getFeedbackSensitivity(), FeedbackSensitivity.medium);
    });
  });
}
