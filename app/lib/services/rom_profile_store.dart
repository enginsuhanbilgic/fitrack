/// Persists [CurlRomProfile] to a single JSON file in app documents.
///
/// **DEPRECATED in WP5.1 (2026-04-XX).** Kept in-tree as a rollback anchor
/// only — production code now uses `SqliteProfileRepository`. The PR1 migrator
/// (`services/db/json_migrator.dart`) reads the legacy file directly without
/// importing this class, so these types are dead code the compiler tree-shakes.
/// Scheduled removal after 2026-05-31.
///
/// Atomic write: write to `.tmp`, flush+close, then rename. Rename within the
/// same directory is atomic on both Android and iOS, so a crash mid-write
/// can't leave a half-written profile in place.
///
/// Schema mismatches → file deleted, telemetry logged, `load()` returns null.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../engine/curl/curl_rom_profile.dart';
import 'telemetry_log.dart';

abstract class RomProfileStore {
  Future<CurlRomProfile?> load();
  Future<void> save(CurlRomProfile profile);
  Future<void> reset();
  Future<bool> exists();
}

class FileRomProfileStore implements RomProfileStore {
  /// Subdirectory under app docs, kept distinct so future per-exercise files
  /// (squat, push-up) coexist cleanly.
  static const String subdir = 'profiles';
  static const String filename = 'biceps_curl.json';

  /// Optional override for tests — provide a `Directory` instead of going to
  /// platform channels via `getApplicationDocumentsDirectory`.
  final Future<Directory> Function()? _docsDirProvider;

  FileRomProfileStore({Future<Directory> Function()? docsDirProvider})
    : _docsDirProvider = docsDirProvider;

  Future<Directory> _docsDir() async {
    if (_docsDirProvider != null) return _docsDirProvider();
    return getApplicationDocumentsDirectory();
  }

  Future<File> _file() async {
    final base = await _docsDir();
    final dir = Directory('${base.path}/$subdir');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File('${dir.path}/$filename');
  }

  @override
  Future<bool> exists() async => (await _file()).existsSync();

  @override
  Future<CurlRomProfile?> load() async {
    final f = await _file();
    if (!f.existsSync()) return null;
    try {
      final raw = await f.readAsString();
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return CurlRomProfile.fromJson(j);
    } catch (e, st) {
      TelemetryLog.instance.log(
        'schema.migration_failed',
        'Failed to load profile; deleting file. error=$e',
        data: {'stackTrace': st.toString()},
      );
      try {
        f.deleteSync();
      } catch (_) {
        // best-effort cleanup
      }
      return null;
    }
  }

  @override
  Future<void> save(CurlRomProfile profile) async {
    final f = await _file();
    final tmp = File('${f.path}.tmp');
    final json = jsonEncode(profile.toJson());
    final sink = tmp.openWrite();
    sink.write(json);
    await sink.flush();
    await sink.close();
    await tmp.rename(f.path);
  }

  @override
  Future<void> reset() async {
    final f = await _file();
    if (f.existsSync()) f.deleteSync();
  }
}

/// In-memory store for tests and previews.
class InMemoryRomProfileStore implements RomProfileStore {
  CurlRomProfile? _profile;

  @override
  Future<bool> exists() async => _profile != null;

  @override
  Future<CurlRomProfile?> load() async => _profile;

  @override
  Future<void> save(CurlRomProfile profile) async {
    _profile = CurlRomProfile.fromJson(
      jsonDecode(jsonEncode(profile.toJson())) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> reset() async => _profile = null;
}
