/// App-lifetime owner of the single sqflite [Database] handle.
///
/// Opens `{docs}/fitrack.db` once in `FiTrackApp.initState` and closes in
/// `dispose`. Repositories receive the `Database` via constructor injection;
/// they do not call `DatabaseService` themselves.
///
/// For tests: pass a [DatabaseFactory] override (typically `databaseFactoryFfi`
/// from `sqflite_common_ffi`) plus a `docsDirProvider` returning a temp dir.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'schema.dart';

abstract class DatabaseService {
  /// Returns the opened handle. Idempotent — subsequent calls reuse the cached
  /// handle. Safe to call from concurrent code paths; the first caller opens,
  /// the rest await the same future.
  Future<Database> database();

  /// Releases the handle. Subsequent `database()` calls will re-open.
  Future<void> close();

  /// The docs directory this service is configured to write in. Exposed so the
  /// `JsonProfileMigrator` can locate the legacy `profiles/biceps_curl.json`
  /// file without re-resolving `path_provider` itself.
  Future<Directory> docsDir();
}

class SqfliteDatabaseService implements DatabaseService {
  SqfliteDatabaseService({
    Future<Directory> Function()? docsDirProvider,
    this.filename = 'fitrack.db',
    DatabaseFactory? factoryOverride,
  }) : _docsDirProvider = docsDirProvider,
       _factory = factoryOverride;

  final Future<Directory> Function()? _docsDirProvider;
  final String filename;
  final DatabaseFactory? _factory;

  Database? _db;
  Future<Database>? _opening;

  @override
  Future<Directory> docsDir() async {
    if (_docsDirProvider != null) return _docsDirProvider();
    return getApplicationDocumentsDirectory();
  }

  @override
  Future<Database> database() {
    final cached = _db;
    if (cached != null && cached.isOpen) return Future.value(cached);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    try {
      final dir = await docsDir();
      final path = '${dir.path}/$filename';
      final options = OpenDatabaseOptions(
        version: kDbSchemaVersion,
        onConfigure: onConfigure,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
      );
      final factory = _factory;
      final db = factory != null
          ? await factory.openDatabase(path, options: options)
          : await openDatabase(
              path,
              version: options.version!,
              onConfigure: options.onConfigure,
              onCreate: options.onCreate,
              onUpgrade: options.onUpgrade,
            );
      _db = db;
      return db;
    } finally {
      _opening = null;
    }
  }

  @override
  Future<void> close() async {
    final db = _db;
    _db = null;
    if (db != null && db.isOpen) {
      await db.close();
    }
  }
}
