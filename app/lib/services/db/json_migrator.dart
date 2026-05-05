/// One-shot migration from `{docs}/profiles/biceps_curl.json` (legacy
/// `FileRomProfileStore` format) to a row in the `profiles` SQLite table.
///
/// Idempotent: running twice is a no-op. Safe to call on every app start.
///
/// Outcome semantics:
///   - [MigrationOutcome.noLegacyFile]        — nothing to migrate.
///   - [MigrationOutcome.skippedAlreadyMigrated] — DB row present; legacy file
///     is left alone (the user can inspect it, or a prior run already renamed
///     it to `.migrated.backup`).
///   - [MigrationOutcome.migrated]             — legacy JSON inserted into DB;
///     file renamed to `.migrated.backup` (with `.N` suffix on collision).
///   - [MigrationOutcome.corruptLegacyFileDropped] — JSON failed to parse or
///     had a mismatched `schemaVersion`; legacy file deleted, telemetry logged,
///     DB untouched.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../engine/curl/curl_rom_profile.dart';
import '../telemetry_log.dart';
import 'profile_repository.dart';

enum MigrationOutcome {
  noLegacyFile,
  migrated,
  skippedAlreadyMigrated,
  corruptLegacyFileDropped,
}

class JsonProfileMigrator {
  JsonProfileMigrator({required Database db, required Directory docsDir})
    : _db = db,
      _docsDir = docsDir;

  final Database _db;
  final Directory _docsDir;

  /// Must match `FileRomProfileStore.subdir` / `.filename`. Hardcoded here
  /// rather than imported so this migrator doesn't pull `rom_profile_store.dart`
  /// into the live runtime graph (it's deprecated and meant to be dead code).
  static const String _legacySubdir = 'profiles';
  static const String _legacyFilename = 'biceps_curl.json';
  static const String _backupSuffix = '.migrated.backup';

  File get _legacyFile =>
      File('${_docsDir.path}/$_legacySubdir/$_legacyFilename');

  Future<MigrationOutcome> migrateIfNeeded() async {
    final legacy = _legacyFile;
    if (!legacy.existsSync()) {
      return MigrationOutcome.noLegacyFile;
    }

    final existing = await _db.query(
      'profiles',
      columns: <String>['profile_key'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[SqliteProfileRepository.curlKey],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return MigrationOutcome.skippedAlreadyMigrated;
    }

    String raw;
    try {
      raw = await legacy.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException(
          'Legacy profile JSON root is not an object',
        );
      }
      // Validate shape before trusting it — if `fromJson` throws on
      // `schemaVersion` mismatch or missing fields, we drop the file rather
      // than persist a poisoned blob.
      CurlRomProfile.fromJson(decoded);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Legacy profile JSON could not be parsed; dropping. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        legacy.deleteSync();
      } catch (_) {
        // best-effort
      }
      return MigrationOutcome.corruptLegacyFileDropped;
    }

    await _db.insert('profiles', <String, Object?>{
      'profile_key': SqliteProfileRepository.curlKey,
      'profile_json': raw,
      'schema_version': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    try {
      await _renameWithUniquify(legacy);
    } catch (e, st) {
      // Rename failure is non-fatal: the DB row is authoritative now, and on
      // next launch the presence of the DB row will route us to
      // `skippedAlreadyMigrated`. Log for forensic visibility.
      TelemetryLog.instance.log(
        'profile.migration.rename_failed',
        'DB row inserted but legacy rename failed. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
    }

    TelemetryLog.instance.log(
      'profile.migrated_to_sqlite',
      'Legacy JSON migrated to profiles table',
    );
    return MigrationOutcome.migrated;
  }

  Future<void> _renameWithUniquify(File legacy) async {
    final base = '${legacy.path}$_backupSuffix';
    var target = base;
    var n = 1;
    while (File(target).existsSync()) {
      target = '$base.$n';
      n++;
    }
    await legacy.rename(target);
  }
}
