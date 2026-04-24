/// Persistence for per-user ROM profiles.
///
/// Replaces [FileRomProfileStore] — the JSON file on disk becomes a JSON blob
/// inside a single row of the `profiles` table. Semantics preserved 1:1:
///
///   - `loadCurl` returns null when no row exists.
///   - On corrupt JSON or schema mismatch: logs `schema.migration_failed`,
///     deletes the row, returns null.
///   - `saveCurl` upserts (REPLACE INTO).
///   - `resetCurl` deletes the row; no-op when missing.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../engine/curl/curl_rom_profile.dart';
import '../telemetry_log.dart';

abstract class ProfileRepository {
  Future<CurlRomProfile?> loadCurl();
  Future<void> saveCurl(CurlRomProfile profile);
  Future<void> resetCurl();
  Future<bool> existsCurl();
}

class SqliteProfileRepository implements ProfileRepository {
  SqliteProfileRepository(this._db);

  final Database _db;

  /// Key used by the curl profile row in the `profiles` table. Stable across
  /// schema evolutions of the embedded JSON; forward-compatible with future
  /// exercise profiles (e.g. `squat_profile_v1`).
  static const String curlKey = 'curl_profile_v1';

  @override
  Future<bool> existsCurl() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_key'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[curlKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<CurlRomProfile?> loadCurl() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_json'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[curlKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['profile_json'] as String?;
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return CurlRomProfile.fromJson(j);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load profile from sqlite; deleting row. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        await _db.delete(
          'profiles',
          where: 'profile_key = ?',
          whereArgs: <Object?>[curlKey],
        );
      } catch (_) {
        // best-effort cleanup — don't mask the original error to the caller
      }
      return null;
    }
  }

  @override
  Future<void> saveCurl(CurlRomProfile profile) async {
    final json = jsonEncode(profile.toJson());
    await _db.insert('profiles', <String, Object?>{
      'profile_key': curlKey,
      'profile_json': json,
      'schema_version': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> resetCurl() async {
    await _db.delete(
      'profiles',
      where: 'profile_key = ?',
      whereArgs: <Object?>[curlKey],
    );
  }
}

/// In-memory double for tests and previews. Matches `InMemoryRomProfileStore`'s
/// deep-copy semantics so tests don't accidentally depend on reference equality.
class InMemoryProfileRepository implements ProfileRepository {
  CurlRomProfile? _profile;

  @override
  Future<bool> existsCurl() async => _profile != null;

  @override
  Future<CurlRomProfile?> loadCurl() async {
    final p = _profile;
    if (p == null) return null;
    return CurlRomProfile.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> saveCurl(CurlRomProfile profile) async {
    _profile = CurlRomProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> resetCurl() async {
    _profile = null;
  }
}
