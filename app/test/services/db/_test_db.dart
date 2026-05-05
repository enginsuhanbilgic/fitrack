/// Shared test infrastructure for SQLite-backed repository tests.
///
/// Uses `sqflite_common_ffi` + `inMemoryDatabasePath` so tests run on the
/// pure-Dart VM without a device/emulator. Matches the project idiom of real
/// I/O over mocks — an in-memory SQLite instance gives authentic transaction
/// and foreign-key semantics rather than a hand-rolled stub.
library;

import 'dart:io';

import 'package:fitrack/services/db/schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Call once per test file, at top of `main()`, before any async setup.
void initSqfliteFfi() {
  sqfliteFfiInit();
}

/// Opens a fresh in-memory database at the current schema version, with
/// `foreign_keys = ON` (required for CASCADE deletes to work).
Future<Database> openTestDb() async {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: kDbSchemaVersion,
      onConfigure: onConfigure,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
    ),
  );
}

/// Creates a temporary docs directory for tests that need a filesystem path
/// (e.g. the JSON migrator). Caller is responsible for `deleteSync(recursive:
/// true)` in `tearDown`.
Directory makeTempDocsDir(String prefix) {
  return Directory.systemTemp.createTempSync(prefix);
}
