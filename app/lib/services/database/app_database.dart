import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String databaseFileName = 'fitrack.db';
  static const int databaseVersion = 2;

  static const String usersTable = 'users';
  static const String userIdentitiesTable = 'user_remote_identities';

  Database? _database;

  Future<Database> get database async {
    final existing = _database;
    if (existing != null) {
      return existing;
    }

    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, databaseFileName);

    final created = await openDatabase(
      path,
      version: databaseVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        await _migrate(db, oldVersion, newVersion);
      },
      onOpen: (db) async {
        await _repairSchemaIfNeeded(db);
      },
    );

    _database = created;
    return created;
  }

  Future<void> close() async {
    final existing = _database;
    if (existing != null) {
      await existing.close();
      _database = null;
    }
  }

  Future<void> _migrate(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 1 && newVersion >= 1) {
      await _createSchema(db);
      return;
    }

    if (oldVersion < 2 && newVersion >= 2) {
      await _repairSchemaIfNeeded(db);
    }
  }

  Future<void> _repairSchemaIfNeeded(Database db) async {
    final usersExists = await _tableExists(db, usersTable);
    if (!usersExists) {
      await _createSchema(db);
      return;
    }

    final hasLocalUuid = await _columnExists(db, usersTable, 'local_uuid');
    if (!hasLocalUuid) {
      await _rebuildFromLegacyUsersTable(db);
    }
  }

  Future<void> _rebuildFromLegacyUsersTable(Database db) async {
    final usersLegacyTable = '${usersTable}_legacy';
    final identitiesLegacyTable = '${userIdentitiesTable}_legacy';

    final usersColumns = await _getColumnNames(db, usersTable);
    final identitiesExists = await _tableExists(db, userIdentitiesTable);
    final identitiesColumns = identitiesExists
        ? await _getColumnNames(db, userIdentitiesTable)
        : <String>{};

    await db.execute('PRAGMA foreign_keys = OFF');
    try {
      await db.transaction((txn) async {
        await txn.execute('ALTER TABLE $usersTable RENAME TO $usersLegacyTable');
        if (identitiesExists) {
          await txn.execute(
            'ALTER TABLE $userIdentitiesTable RENAME TO $identitiesLegacyTable',
          );
        }

        await _createSchema(txn);

        final nowExpr = "strftime('%Y-%m-%dT%H:%M:%fZ','now')";
        final idExpr = usersColumns.contains('id') ? 'id' : 'NULL';
        final displayNameExpr = usersColumns.contains('display_name')
            ? 'display_name'
            : 'NULL';
        final emailExpr = usersColumns.contains('email') ? 'email' : 'NULL';
        final authModeExpr = usersColumns.contains('auth_mode')
            ? 'auth_mode'
            : "'LOCAL'";
        final isActiveExpr = usersColumns.contains('is_active')
            ? 'is_active'
            : '1';
        final createdAtExpr = usersColumns.contains('created_at')
            ? 'created_at'
            : nowExpr;
        final updatedAtExpr = usersColumns.contains('updated_at')
            ? 'updated_at'
            : nowExpr;

        await txn.execute('''
          INSERT INTO $usersTable (
            id,
            local_uuid,
            display_name,
            email,
            auth_mode,
            is_active,
            created_at,
            updated_at
          )
          SELECT
            $idExpr,
            lower(hex(randomblob(16))),
            $displayNameExpr,
            $emailExpr,
            $authModeExpr,
            $isActiveExpr,
            $createdAtExpr,
            $updatedAtExpr
          FROM $usersLegacyTable
        ''');

        if (identitiesExists) {
          final hasAllIdentityColumns = identitiesColumns.containsAll(<String>{
            'id',
            'user_id',
            'provider_type',
            'remote_user_id',
            'remote_email',
            'linked_at',
            'last_sync_at',
          });

          if (hasAllIdentityColumns) {
            await txn.execute('''
              INSERT INTO $userIdentitiesTable (
                id,
                user_id,
                provider_type,
                remote_user_id,
                remote_email,
                linked_at,
                last_sync_at
              )
              SELECT
                id,
                user_id,
                provider_type,
                remote_user_id,
                remote_email,
                linked_at,
                last_sync_at
              FROM $identitiesLegacyTable
            ''');
          }
        }

        await txn.execute('DROP TABLE $usersLegacyTable');
        if (identitiesExists) {
          await txn.execute('DROP TABLE $identitiesLegacyTable');
        }
      });
    } finally {
      await db.execute('PRAGMA foreign_keys = ON');
    }
  }

  Future<bool> _tableExists(DatabaseExecutor db, String tableName) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[tableName],
    );
    return rows.isNotEmpty;
  }

  Future<bool> _columnExists(
    DatabaseExecutor db,
    String tableName,
    String columnName,
  ) async {
    final columns = await _getColumnNames(db, tableName);
    return columns.contains(columnName);
  }

  Future<Set<String>> _getColumnNames(
    DatabaseExecutor db,
    String tableName,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($tableName)');
    return rows
        .map((row) => row['name'] as String)
        .toSet();
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    if (await _tableExists(db, usersTable) ||
        await _tableExists(db, userIdentitiesTable)) {
      await db.execute('DROP TABLE IF EXISTS $userIdentitiesTable');
      await db.execute('DROP TABLE IF EXISTS $usersTable');
    }

    await db.execute('''
      CREATE TABLE $usersTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        local_uuid TEXT NOT NULL UNIQUE,
        display_name TEXT,
        email TEXT,
        auth_mode TEXT NOT NULL
          CHECK(auth_mode IN ('LOCAL', 'REMOTE')),
        is_active INTEGER NOT NULL DEFAULT 1
          CHECK(is_active IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_users_auth_mode ON $usersTable(auth_mode)',
    );
    await db.execute('CREATE INDEX idx_users_email ON $usersTable(email)');

    await db.execute('''
      CREATE TABLE $userIdentitiesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        provider_type TEXT NOT NULL,
        remote_user_id TEXT NOT NULL,
        remote_email TEXT,
        linked_at TEXT NOT NULL,
        last_sync_at TEXT,
        FOREIGN KEY(user_id) REFERENCES $usersTable(id) ON DELETE CASCADE,
        UNIQUE(provider_type, remote_user_id),
        UNIQUE(user_id, provider_type)
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_user_remote_identities_user_id '
      'ON $userIdentitiesTable(user_id)',
    );
  }
}
