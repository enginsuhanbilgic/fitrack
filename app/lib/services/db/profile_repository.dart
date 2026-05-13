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
import '../../engine/push_up/push_up_rom_profile.dart';
import '../../engine/squat/squat_rom_profile.dart';
import '../telemetry_log.dart';

abstract class ProfileRepository {
  Future<CurlRomProfile?> loadCurl();
  Future<void> saveCurl(CurlRomProfile profile);
  Future<void> resetCurl();
  Future<bool> existsCurl();

  Future<PushUpRomProfile?> loadPushUp() async => null;
  Future<void> savePushUp(PushUpRomProfile profile) async {}
  Future<void> resetPushUp() async {}
  Future<bool> existsPushUp() async => false;

  Future<SquatRomProfile?> loadSquat() async => null;
  Future<void> saveSquat(SquatRomProfile profile) async {}
  Future<void> resetSquat() async {}
  Future<bool> existsSquat() async => false;

  // ── Demo ROM profiles (separate keyspace per ADR-2) ──
  //
  // Demo profiles live under `demo_curl_profile_v1` / `demo_squat_profile_v1`
  // / `demo_push_up_profile_v1` keys, NOT under an `is_demo` flag column on
  // the live keys. This prevents the live `saveCurl()` auto-calibration
  // write path from silently clobbering a demo profile.

  Future<CurlRomProfile?> loadDemoCurl() async => null;
  Future<void> saveDemoCurl(CurlRomProfile profile) async {}

  Future<SquatRomProfile?> loadDemoSquat() async => null;
  Future<void> saveDemoSquat(SquatRomProfile profile) async {}

  Future<PushUpRomProfile?> loadDemoPushUp() async => null;
  Future<void> saveDemoPushUp(PushUpRomProfile profile) async {}

  /// Wipes every row in `profiles` whose key starts with `demo_`. Used by
  /// `DemoService.enableAndSeed` step 3 and `DemoService.disable` step 2.
  /// Returns the number of rows deleted.
  Future<int> deleteDemoProfiles() async => 0;
}

class SqliteProfileRepository implements ProfileRepository {
  SqliteProfileRepository(this._db);

  final Database _db;

  /// Key used by the curl profile row in the `profiles` table. Stable across
  /// schema evolutions of the embedded JSON; forward-compatible with future
  /// exercise profiles (e.g. `squat_profile_v1`).
  static const String curlKey = 'curl_profile_v1';
  static const String pushUpKey = 'push_up_profile_v1';
  static const String squatKey = 'squat_profile_v1';

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
  Future<bool> existsPushUp() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_key'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[pushUpKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<PushUpRomProfile?> loadPushUp() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_json'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[pushUpKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['profile_json'] as String?;
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return PushUpRomProfile.fromJson(j);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load push-up profile from sqlite; deleting row. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        await _db.delete(
          'profiles',
          where: 'profile_key = ?',
          whereArgs: <Object?>[pushUpKey],
        );
      } catch (_) {
        // best-effort cleanup
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
  Future<void> savePushUp(PushUpRomProfile profile) async {
    final json = jsonEncode(profile.toJson());
    await _db.insert('profiles', <String, Object?>{
      'profile_key': pushUpKey,
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

  @override
  Future<void> resetPushUp() async {
    await _db.delete(
      'profiles',
      where: 'profile_key = ?',
      whereArgs: <Object?>[pushUpKey],
    );
  }

  @override
  Future<bool> existsSquat() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_key'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[squatKey],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<SquatRomProfile?> loadSquat() async {
    final rows = await _db.query(
      'profiles',
      columns: <String>['profile_json'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[squatKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['profile_json'] as String?;
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return SquatRomProfile.fromJson(j);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load squat profile from sqlite; deleting row. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        await _db.delete(
          'profiles',
          where: 'profile_key = ?',
          whereArgs: <Object?>[squatKey],
        );
      } catch (_) {
        // best-effort cleanup
      }
      return null;
    }
  }

  @override
  Future<void> saveSquat(SquatRomProfile profile) async {
    final json = jsonEncode(profile.toJson());
    await _db.insert('profiles', <String, Object?>{
      'profile_key': squatKey,
      'profile_json': json,
      'schema_version': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> resetSquat() async {
    await _db.delete(
      'profiles',
      where: 'profile_key = ?',
      whereArgs: <Object?>[squatKey],
    );
  }

  // ── Demo ROM keyspace (per ADR-2) ──

  static const String demoCurlKey = 'demo_curl_profile_v1';
  static const String demoSquatKey = 'demo_squat_profile_v1';
  static const String demoPushUpKey = 'demo_push_up_profile_v1';

  @override
  Future<CurlRomProfile?> loadDemoCurl() async =>
      _loadJson(demoCurlKey, CurlRomProfile.fromJson);

  @override
  Future<void> saveDemoCurl(CurlRomProfile profile) =>
      _saveJson(demoCurlKey, profile.toJson());

  @override
  Future<SquatRomProfile?> loadDemoSquat() async =>
      _loadJson(demoSquatKey, SquatRomProfile.fromJson);

  @override
  Future<void> saveDemoSquat(SquatRomProfile profile) =>
      _saveJson(demoSquatKey, profile.toJson());

  @override
  Future<PushUpRomProfile?> loadDemoPushUp() async =>
      _loadJson(demoPushUpKey, PushUpRomProfile.fromJson);

  @override
  Future<void> saveDemoPushUp(PushUpRomProfile profile) =>
      _saveJson(demoPushUpKey, profile.toJson());

  @override
  Future<int> deleteDemoProfiles() async {
    return _db.delete('profiles', where: "profile_key LIKE 'demo_%'");
  }

  Future<T?> _loadJson<T>(
    String key,
    T Function(Map<String, dynamic>) parser,
  ) async {
    final rows = await _db.query(
      'profiles',
      columns: const <String>['profile_json'],
      where: 'profile_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final raw = rows.first['profile_json'] as String?;
    if (raw == null) return null;
    try {
      return parser(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load demo profile $key from sqlite; deleting. error=$e',
        data: <String, Object?>{'stackTrace': st.toString()},
      );
      try {
        await _db.delete(
          'profiles',
          where: 'profile_key = ?',
          whereArgs: <Object?>[key],
        );
      } catch (_) {
        // best-effort cleanup
      }
      return null;
    }
  }

  Future<void> _saveJson(String key, Map<String, dynamic> json) async {
    await _db.insert('profiles', <String, Object?>{
      'profile_key': key,
      'profile_json': jsonEncode(json),
      'schema_version': 1,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// In-memory double for tests and previews. Matches `InMemoryRomProfileStore`'s
/// deep-copy semantics so tests don't accidentally depend on reference equality.
class InMemoryProfileRepository implements ProfileRepository {
  CurlRomProfile? _profile;
  PushUpRomProfile? _pushUpProfile;
  SquatRomProfile? _squatProfile;
  CurlRomProfile? _demoCurl;
  SquatRomProfile? _demoSquat;
  PushUpRomProfile? _demoPushUp;

  @override
  Future<bool> existsCurl() async => _profile != null;

  @override
  Future<bool> existsPushUp() async => _pushUpProfile != null;

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

  @override
  Future<PushUpRomProfile?> loadPushUp() async {
    final p = _pushUpProfile;
    if (p == null) return null;
    return PushUpRomProfile.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> savePushUp(PushUpRomProfile profile) async {
    _pushUpProfile = PushUpRomProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> resetPushUp() async {
    _pushUpProfile = null;
  }

  @override
  Future<bool> existsSquat() async => _squatProfile != null;

  @override
  Future<SquatRomProfile?> loadSquat() async {
    final p = _squatProfile;
    if (p == null) return null;
    return SquatRomProfile.fromJson(
      jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> saveSquat(SquatRomProfile profile) async {
    _squatProfile = SquatRomProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> resetSquat() async {
    _squatProfile = null;
  }

  // ── Demo ROM keyspace (per ADR-2) ──

  @override
  Future<CurlRomProfile?> loadDemoCurl() async => _demoCurl;

  @override
  Future<void> saveDemoCurl(CurlRomProfile profile) async {
    _demoCurl = profile;
  }

  @override
  Future<SquatRomProfile?> loadDemoSquat() async => _demoSquat;

  @override
  Future<void> saveDemoSquat(SquatRomProfile profile) async {
    _demoSquat = profile;
  }

  @override
  Future<PushUpRomProfile?> loadDemoPushUp() async => _demoPushUp;

  @override
  Future<void> saveDemoPushUp(PushUpRomProfile profile) async {
    _demoPushUp = profile;
  }

  @override
  Future<int> deleteDemoProfiles() async {
    var n = 0;
    if (_demoCurl != null) {
      _demoCurl = null;
      n++;
    }
    if (_demoSquat != null) {
      _demoSquat = null;
      n++;
    }
    if (_demoPushUp != null) {
      _demoPushUp = null;
      n++;
    }
    return n;
  }
}
