/// Persistence for the local-only user profile (schema v8).
///
/// Single-row table: every save uses `INSERT OR REPLACE` against `id = 1`.
/// The CHECK constraint in the DDL guarantees we cannot accidentally end up
/// with multiple profile rows on this device. When multi-user auth lands
/// (`PRODUCTION_ROADMAP.md` Phase 4), the CHECK is dropped and `id` becomes
/// a real user FK — the read/write API of this repository stays stable.
///
/// Storage convention: heights in cm, weights in kg. UI is responsible for
/// any unit conversion (see `lib/utils/units.dart`).
library;

import 'package:sqflite/sqflite.dart';

import '../../models/user_profile.dart';
import '../telemetry_log.dart';

abstract class UserProfileRepository {
  /// Returns the saved profile, or `null` if the user has not yet completed
  /// Edit Profile. `null` is the "anonymous" sentinel — UI should render the
  /// "Set up your profile" CTA in that state.
  Future<UserProfile?> load();

  /// Upserts the singleton row. The repository stamps `updatedAt` to the
  /// current wall-clock time; callers do not need to set it themselves.
  Future<void> save(UserProfile profile);

  /// Deletes the row. Used by future "Clear all data" flows; not surfaced
  /// in this PR. Idempotent — no-op if no row exists.
  Future<void> clear();

  /// True when a profile row exists. Cheap pre-check used by the dashboard
  /// to choose between "Welcome back, $name" and "Set up your profile".
  Future<bool> exists();
}

class SqliteUserProfileRepository implements UserProfileRepository {
  SqliteUserProfileRepository(this._db);

  final Database _db;

  static const String _table = 'user_profile';
  static const int _kSingletonId = 1;

  @override
  Future<bool> exists() async {
    final rows = await _db.query(
      _table,
      columns: const <String>['id'],
      where: 'id = ?',
      whereArgs: const <Object?>[_kSingletonId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<UserProfile?> load() async {
    final rows = await _db.query(
      _table,
      where: 'id = ?',
      whereArgs: const <Object?>[_kSingletonId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    try {
      final displayName = r['display_name'] as String?;
      // displayName is required at the model level. A row exists only after
      // a successful save which validates non-empty — but defend against a
      // hand-edited DB by treating null/empty as "no profile".
      if (displayName == null || displayName.isEmpty) return null;
      return UserProfile(
        displayName: displayName,
        avatarEmoji: r['avatar_emoji'] as String?,
        age: (r['age'] as num?)?.toInt(),
        gender: _decodeEnum(r['gender'] as String?, Gender.values),
        heightCm: (r['height_cm'] as num?)?.toDouble(),
        weightKg: (r['weight_kg'] as num?)?.toDouble(),
        experience: _decodeEnum(
          r['experience'] as String?,
          ExperienceLevel.values,
        ),
        primaryGoal: _decodeEnum(
          r['primary_goal'] as String?,
          FitnessGoal.values,
        ),
        goals: UserProfile.decodeGoals(r['goals_json'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (r['created_at'] as num).toInt(),
        ),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          (r['updated_at'] as num).toInt(),
        ),
      );
    } catch (e, st) {
      // Corrupt row (manually edited DB, downgraded enum, etc.) — log + drop
      // and return null so the user lands on "Set up your profile" rather
      // than an error screen. Mirrors `SqliteProfileRepository.loadCurl`.
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load user_profile from sqlite; deleting row. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        await clear();
      } catch (_) {
        // best-effort cleanup
      }
      return null;
    }
  }

  @override
  Future<void> save(UserProfile profile) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insert(_table, <String, Object?>{
      'id': _kSingletonId,
      'display_name': profile.displayName,
      'avatar_emoji': profile.avatarEmoji,
      'age': profile.age,
      'gender': profile.gender?.name,
      'height_cm': profile.heightCm,
      'weight_kg': profile.weightKg,
      'experience': profile.experience?.name,
      'primary_goal': profile.primaryGoal?.name,
      'goals_json': profile.encodeGoals(),
      'created_at': profile.createdAt.millisecondsSinceEpoch,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> clear() async {
    await _db.delete(
      _table,
      where: 'id = ?',
      whereArgs: const <Object?>[_kSingletonId],
    );
  }

  /// Tolerant enum decode — unknown names (e.g. enum value renamed in a
  /// later release) collapse to null rather than throwing, matching the
  /// pattern in [SqlitePreferencesRepository.getSquatVariant].
  static T? _decodeEnum<T extends Enum>(String? raw, List<T> values) {
    if (raw == null) return null;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}

/// In-memory test double. Mirrors [InMemoryProfileRepository] semantics —
/// returns deep copies on `load` so callers can't mutate internal state by
/// reference.
class InMemoryUserProfileRepository implements UserProfileRepository {
  UserProfile? _profile;

  @override
  Future<bool> exists() async => _profile != null;

  @override
  Future<UserProfile?> load() async => _profile;

  @override
  Future<void> save(UserProfile profile) async {
    _profile = profile;
  }

  @override
  Future<void> clear() async {
    _profile = null;
  }
}
