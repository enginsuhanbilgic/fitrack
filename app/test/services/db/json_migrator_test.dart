import 'dart:convert';
import 'dart:io';

import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';
import 'package:fitrack/services/db/json_migrator.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/telemetry_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  late Database db;
  late Directory tmp;
  late JsonProfileMigrator migrator;

  setUp(() async {
    db = await openTestDb();
    tmp = makeTempDocsDir('fitrack_migrator_test_');
    migrator = JsonProfileMigrator(db: db, docsDir: tmp);
    TelemetryLog.instance.clear();
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void writeLegacy(String contents) {
    final profilesDir = Directory('${tmp.path}/profiles')
      ..createSync(recursive: true);
    File('${profilesDir.path}/biceps_curl.json').writeAsStringSync(contents);
  }

  File legacyFile() => File('${tmp.path}/profiles/biceps_curl.json');
  File backupFile() =>
      File('${tmp.path}/profiles/biceps_curl.json.migrated.backup');

  String validLegacyJson() {
    final p = CurlRomProfile()
      ..upsertBucket(
        RomBucket(
          side: ProfileSide.left,
          view: CurlCameraView.front,
          observedMinAngle: 55,
          observedMaxAngle: 170,
          sampleCount: 7,
        ),
      );
    return jsonEncode(p.toJson());
  }

  test('noLegacyFile when file absent and DB empty', () async {
    expect(await migrator.migrateIfNeeded(), MigrationOutcome.noLegacyFile);
    expect(legacyFile().existsSync(), isFalse);
    expect(backupFile().existsSync(), isFalse);
  });

  test(
    'migrates legacy JSON, renames to .migrated.backup, logs telemetry',
    () async {
      writeLegacy(validLegacyJson());

      final outcome = await migrator.migrateIfNeeded();

      expect(outcome, MigrationOutcome.migrated);
      expect(legacyFile().existsSync(), isFalse);
      expect(backupFile().existsSync(), isTrue);

      // DB row present with the same JSON blob.
      final rows = await db.query('profiles');
      expect(rows, hasLength(1));
      expect(rows.first['profile_key'], SqliteProfileRepository.curlKey);

      // Telemetry: success event emitted.
      expect(
        TelemetryLog.instance.entries.any(
          (e) => e.tag == 'profile.migrated_to_sqlite',
        ),
        isTrue,
      );

      // Profile loads through the repository end-to-end.
      final repo = SqliteProfileRepository(db);
      final loaded = (await repo.loadCurl())!;
      final b = loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!;
      expect(b.observedMinAngle, 55);
      expect(b.sampleCount, 7);
    },
  );

  test('idempotent: second run returns skippedAlreadyMigrated', () async {
    writeLegacy(validLegacyJson());

    final first = await migrator.migrateIfNeeded();
    expect(first, MigrationOutcome.migrated);
    expect(backupFile().existsSync(), isTrue);

    // Second run: legacy file is gone, DB row exists, so we hit `noLegacyFile`.
    final second = await migrator.migrateIfNeeded();
    expect(second, MigrationOutcome.noLegacyFile);

    // Simulate a user manually putting the legacy file back (e.g. sideloaded
    // from a backup) — DB row wins.
    writeLegacy(validLegacyJson());
    final third = await migrator.migrateIfNeeded();
    expect(third, MigrationOutcome.skippedAlreadyMigrated);
    expect(
      legacyFile().existsSync(),
      isTrue,
      reason: 'skippedAlreadyMigrated must leave the legacy file untouched',
    );
  });

  test('corrupt JSON → drops legacy, logs telemetry', () async {
    writeLegacy('not valid json {{{');

    final outcome = await migrator.migrateIfNeeded();

    expect(outcome, MigrationOutcome.corruptLegacyFileDropped);
    expect(legacyFile().existsSync(), isFalse);
    expect(backupFile().existsSync(), isFalse);
    final rows = await db.query('profiles');
    expect(rows, isEmpty);
    expect(
      TelemetryLog.instance.entries.any(
        (e) => e.tag == 'schema.migration_failed',
      ),
      isTrue,
    );
  });

  test('legacy with wrong schemaVersion → drops', () async {
    writeLegacy(
      jsonEncode(<String, Object?>{
        'schemaVersion': 999,
        'userId': 'local_user',
        'createdAt': DateTime.now().toIso8601String(),
        'lastUsedAt': DateTime.now().toIso8601String(),
        'buckets': <Map<String, dynamic>>[],
      }),
    );

    final outcome = await migrator.migrateIfNeeded();
    expect(outcome, MigrationOutcome.corruptLegacyFileDropped);
    expect(legacyFile().existsSync(), isFalse);
    final rows = await db.query('profiles');
    expect(rows, isEmpty);
  });

  test('legacy JSON root that is not an object → drops', () async {
    writeLegacy('[1,2,3]');
    final outcome = await migrator.migrateIfNeeded();
    expect(outcome, MigrationOutcome.corruptLegacyFileDropped);
    expect(legacyFile().existsSync(), isFalse);
  });

  test('backup collision uniquifies with .N suffix', () async {
    // Seed an existing .migrated.backup file (simulates a prior partial run).
    final profilesDir = Directory('${tmp.path}/profiles')
      ..createSync(recursive: true);
    File(
      '${profilesDir.path}/biceps_curl.json.migrated.backup',
    ).writeAsStringSync('{"schemaVersion":1,"stale":true}');

    writeLegacy(validLegacyJson());

    final outcome = await migrator.migrateIfNeeded();
    expect(outcome, MigrationOutcome.migrated);

    // Original backup preserved; new one got `.1` suffix.
    expect(
      File('${profilesDir.path}/biceps_curl.json.migrated.backup').existsSync(),
      isTrue,
    );
    expect(
      File(
        '${profilesDir.path}/biceps_curl.json.migrated.backup.1',
      ).existsSync(),
      isTrue,
    );
    expect(legacyFile().existsSync(), isFalse);
  });
}
