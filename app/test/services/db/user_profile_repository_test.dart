/// Round-trip + edge-case tests for [SqliteUserProfileRepository] —
/// schema v8 single-row local user profile.
library;

import 'package:fitrack/models/user_profile.dart';
import 'package:fitrack/services/db/user_profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('SqliteUserProfileRepository', () {
    test('load returns null when no profile saved', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      expect(await repo.load(), isNull);
      expect(await repo.exists(), isFalse);
      await db.close();
    });

    test('save then load round-trips every field', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      final created = DateTime(2026, 5, 13);
      final goal = UserGoal(
        id: created.millisecondsSinceEpoch,
        title: 'First push-up',
        detail: 'Start with knees',
        createdAt: created,
      );
      final p = UserProfile(
        displayName: 'Test User',
        avatarEmoji: '💪',
        age: 28,
        gender: Gender.female,
        heightCm: 168,
        weightKg: 62.5,
        experience: ExperienceLevel.intermediate,
        primaryGoal: FitnessGoal.buildMuscle,
        goals: [goal],
        createdAt: created,
        updatedAt: created,
      );
      await repo.save(p);

      final loaded = await repo.load();
      expect(loaded, isNotNull);
      expect(loaded!.displayName, 'Test User');
      expect(loaded.avatarEmoji, '💪');
      expect(loaded.age, 28);
      expect(loaded.gender, Gender.female);
      expect(loaded.heightCm, 168);
      expect(loaded.weightKg, 62.5);
      expect(loaded.experience, ExperienceLevel.intermediate);
      expect(loaded.primaryGoal, FitnessGoal.buildMuscle);
      expect(loaded.goals.length, 1);
      expect(loaded.goals.first.title, 'First push-up');
      expect(
        loaded.createdAt.millisecondsSinceEpoch,
        created.millisecondsSinceEpoch,
      );
      // updatedAt is stamped by the repo, so it may be newer than the
      // value we passed in. The contract: updatedAt >= passed value.
      expect(
        loaded.updatedAt.isAtSameMomentAs(created) ||
            loaded.updatedAt.isAfter(created),
        isTrue,
      );

      await db.close();
    });

    test('save with all-null demographics still works', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      final p = UserProfile(
        displayName: 'Anon',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      await repo.save(p);

      final loaded = await repo.load();
      expect(loaded?.displayName, 'Anon');
      expect(loaded?.age, isNull);
      expect(loaded?.heightCm, isNull);
      expect(loaded?.gender, isNull);
      expect(loaded?.goals, isEmpty);
      await db.close();
    });

    test('save twice updates the singleton row, no duplicates', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      final base = UserProfile(
        displayName: 'First',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );
      await repo.save(base);
      await repo.save(base.copyWith(displayName: 'Second'));

      final loaded = await repo.load();
      expect(loaded?.displayName, 'Second');

      // Direct count check confirms the CHECK (id = 1) singleton invariant.
      final rows = await db.query('user_profile');
      expect(rows.length, 1);
      await db.close();
    });

    test('clear removes the row; subsequent load returns null', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      await repo.save(
        UserProfile(
          displayName: 'Will be cleared',
          createdAt: DateTime(2026, 1, 1),
          updatedAt: DateTime(2026, 1, 1),
        ),
      );
      expect(await repo.exists(), isTrue);
      await repo.clear();
      expect(await repo.exists(), isFalse);
      expect(await repo.load(), isNull);
      await db.close();
    });

    test('clear on empty DB is a safe no-op', () async {
      final db = await openTestDb();
      final repo = SqliteUserProfileRepository(db);
      await repo.clear(); // must not throw
      expect(await repo.exists(), isFalse);
      await db.close();
    });
  });
}
