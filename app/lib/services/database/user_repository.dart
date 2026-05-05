import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/app_user.dart';
import '../../models/user_remote_identity.dart';
import 'app_database.dart';

class UserWithIdentities {
  final AppUser user;
  final List<UserRemoteIdentity> identities;

  const UserWithIdentities({required this.user, required this.identities});
}

class UserRepository {
  UserRepository({AppDatabase? database})
      : _database = database ?? AppDatabase.instance;

  final AppDatabase _database;
  static const Uuid _uuid = Uuid();

  Future<AppUser> createLocalUser({
    String? displayName,
    String? email,
    String? localUuid,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();

    final userId = await db.transaction((txn) async {
      await _clearActiveUsers(txn, now);
      return txn.insert(
        AppDatabase.usersTable,
        <String, Object?>{
          'local_uuid': localUuid ?? _newUuid(),
          'display_name': displayName,
          'email': email,
          'auth_mode': AuthMode.local.dbValue,
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
    });

    final user = await getUserById(userId);
    if (user == null) {
      throw StateError('Failed to load user after creation');
    }
    return user;
  }

  Future<AppUser> createRemoteUser({
    required RemoteProviderType providerType,
    required String remoteUserId,
    String? displayName,
    String? email,
    String? remoteEmail,
    String? localUuid,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();

    final created = await db.transaction((txn) async {
      await _clearActiveUsers(txn, now);

      final userId = await txn.insert(
        AppDatabase.usersTable,
        <String, Object?>{
          'local_uuid': localUuid ?? _newUuid(),
          'display_name': displayName,
          'email': email ?? remoteEmail,
          'auth_mode': AuthMode.remote.dbValue,
          'is_active': 1,
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      await txn.insert(
        AppDatabase.userIdentitiesTable,
        <String, Object?>{
          'user_id': userId,
          'provider_type': providerType.dbValue,
          'remote_user_id': remoteUserId,
          'remote_email': remoteEmail,
          'linked_at': now,
          'last_sync_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      return userId;
    });

    final user = await getUserById(created);
    if (user == null) {
      throw StateError('Failed to load user after creation');
    }
    return user;
  }

  Future<void> linkRemoteIdentity({
    required int userId,
    required RemoteProviderType providerType,
    required String remoteUserId,
    String? remoteEmail,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();

    await db.transaction((txn) async {
      final count = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.usersTable} WHERE id = ?',
          <Object?>[userId],
        ),
      );
      if (count == null || count == 0) {
        throw StateError('Cannot link identity for missing user id=$userId');
      }

      await txn.insert(
        AppDatabase.userIdentitiesTable,
        <String, Object?>{
          'user_id': userId,
          'provider_type': providerType.dbValue,
          'remote_user_id': remoteUserId,
          'remote_email': remoteEmail,
          'linked_at': now,
          'last_sync_at': null,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );

      await txn.update(
        AppDatabase.usersTable,
        <String, Object?>{
          'auth_mode': AuthMode.remote.dbValue,
          'updated_at': now,
          ...?remoteEmail == null ? null : <String, Object?>{'email': remoteEmail},
        },
        where: 'id = ?',
        whereArgs: <Object?>[userId],
      );
    });
  }

  Future<AppUser?> getUserById(int id) async {
    final db = await _database.database;
    final rows = await db.query(
      AppDatabase.usersTable,
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }
    return AppUser.fromMap(rows.first);
  }

  Future<AppUser?> getUserByLocalUuid(String localUuid) async {
    final db = await _database.database;
    final rows = await db.query(
      AppDatabase.usersTable,
      where: 'local_uuid = ?',
      whereArgs: <Object?>[localUuid],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }
    return AppUser.fromMap(rows.first);
  }

  Future<AppUser?> getFirstActiveUser() async {
    final db = await _database.database;
    final rows = await db.query(
      AppDatabase.usersTable,
      where: 'is_active = 1',
      orderBy: 'id ASC',
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }
    return AppUser.fromMap(rows.first);
  }

  Future<List<AppUser>> getAllUsers() async {
    final db = await _database.database;
    final rows = await db.query(
      AppDatabase.usersTable,
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(AppUser.fromMap).toList(growable: false);
  }

  Future<void> setActiveUser(int userId) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();

    await db.transaction((txn) async {
      final exists = Sqflite.firstIntValue(
        await txn.rawQuery(
          'SELECT COUNT(*) FROM ${AppDatabase.usersTable} WHERE id = ?',
          <Object?>[userId],
        ),
      );
      if ((exists ?? 0) == 0) {
        throw StateError('Cannot activate missing user id=$userId');
      }

      await _clearActiveUsers(txn, now);
      await txn.update(
        AppDatabase.usersTable,
        <String, Object?>{'is_active': 1, 'updated_at': now},
        where: 'id = ?',
        whereArgs: <Object?>[userId],
      );
    });
  }

  Future<void> signOutAllUsers() async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await _clearActiveUsers(db, now);
  }

  Future<UserWithIdentities?> getUserWithIdentities(int userId) async {
    final db = await _database.database;
    final user = await getUserById(userId);
    if (user == null) {
      return null;
    }

    final identityRows = await db.query(
      AppDatabase.userIdentitiesTable,
      where: 'user_id = ?',
      whereArgs: <Object?>[userId],
      orderBy: 'id ASC',
    );

    final identities = identityRows
        .map(UserRemoteIdentity.fromMap)
        .toList(growable: false);

    return UserWithIdentities(user: user, identities: identities);
  }

  Future<UserWithIdentities?> findByRemoteIdentity({
    required RemoteProviderType providerType,
    required String remoteUserId,
  }) async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT user_id FROM ${AppDatabase.userIdentitiesTable} '
      'WHERE provider_type = ? AND remote_user_id = ? LIMIT 1',
      <Object?>[providerType.dbValue, remoteUserId],
    );

    if (rows.isEmpty) {
      return null;
    }

    final userId = rows.first['user_id'] as int;
    return getUserWithIdentities(userId);
  }

  Future<AppUser?> seedInitialLocalUserIfEmpty({
    String? displayName,
  }) async {
    final db = await _database.database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) FROM ${AppDatabase.usersTable}',
      ),
    );

    if ((count ?? 0) > 0) {
      return null;
    }

    return createLocalUser(displayName: displayName ?? 'FiTrack User');
  }

  String _newUuid() {
    return _uuid.v4();
  }

  Future<void> _clearActiveUsers(DatabaseExecutor db, String now) async {
    await db.update(
      AppDatabase.usersTable,
      <String, Object?>{'is_active': 0, 'updated_at': now},
      where: 'is_active = 1',
    );
  }
}
