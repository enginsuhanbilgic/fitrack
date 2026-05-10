import 'dart:convert';

import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';
import 'package:fitrack/engine/push_up/push_up_rom_profile.dart';
import 'package:fitrack/services/db/profile_repository.dart';
import 'package:fitrack/services/telemetry_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import '_test_db.dart';

void main() {
  initSqfliteFfi();

  group('SqliteProfileRepository', () {
    late Database db;
    late SqliteProfileRepository repo;

    setUp(() async {
      db = await openTestDb();
      repo = SqliteProfileRepository(db);
      TelemetryLog.instance.clear();
    });

    tearDown(() async {
      await db.close();
    });

    test('loadCurl returns null when no row exists', () async {
      expect(await repo.loadCurl(), isNull);
      expect(await repo.existsCurl(), isFalse);
    });

    test('saveCurl then loadCurl round-trips a profile faithfully', () async {
      final p = CurlRomProfile(userId: 'local_user');
      p.upsertBucket(
        RomBucket(
          side: ProfileSide.left,
          view: CurlCameraView.front,
          observedMinAngle: 60,
          observedMaxAngle: 165,
          sampleCount: 5,
        ),
      );
      await repo.saveCurl(p);

      final loaded = (await repo.loadCurl())!;
      expect(loaded.userId, 'local_user');
      final b = loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!;
      expect(b.observedMinAngle, 60);
      expect(b.observedMaxAngle, 165);
      expect(b.sampleCount, 5);
      expect(await repo.existsCurl(), isTrue);
    });

    test('saveCurl upserts (REPLACE INTO semantics)', () async {
      final p1 = CurlRomProfile()
        ..upsertBucket(
          RomBucket(
            side: ProfileSide.left,
            view: CurlCameraView.front,
            observedMinAngle: 60,
            observedMaxAngle: 165,
            sampleCount: 1,
          ),
        );
      await repo.saveCurl(p1);

      final p2 = CurlRomProfile()
        ..upsertBucket(
          RomBucket(
            side: ProfileSide.left,
            view: CurlCameraView.front,
            observedMinAngle: 50,
            observedMaxAngle: 170,
            sampleCount: 9,
          ),
        );
      await repo.saveCurl(p2);

      // Exactly one row remains, with the newer values.
      final rows = await db.query('profiles');
      expect(rows, hasLength(1));

      final loaded = (await repo.loadCurl())!;
      final b = loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!;
      expect(b.observedMinAngle, 50);
      expect(b.sampleCount, 9);
    });

    test('resetCurl deletes the row', () async {
      final p = CurlRomProfile()
        ..upsertBucket(RomBucket.empty(ProfileSide.left, CurlCameraView.front));
      await repo.saveCurl(p);
      expect(await repo.existsCurl(), isTrue);

      await repo.resetCurl();
      expect(await repo.existsCurl(), isFalse);
      expect(await repo.loadCurl(), isNull);
    });

    test('resetCurl on missing row is a no-op (does not throw)', () async {
      await expectLater(repo.resetCurl(), completes);
    });

    test('savePushUp then loadPushUp round-trips profile', () async {
      final p = PushUpRomProfile.calibrated(topAngle: 170, bottomAngle: 82);
      await repo.savePushUp(p);

      final loaded = (await repo.loadPushUp())!;
      expect(loaded.topAngle, 170);
      expect(loaded.bottomAngle, 82);
      expect(await repo.existsPushUp(), isTrue);
    });

    test('resetPushUp deletes only the push-up row', () async {
      await repo.saveCurl(CurlRomProfile());
      await repo.savePushUp(
        PushUpRomProfile.calibrated(topAngle: 170, bottomAngle: 82),
      );

      await repo.resetPushUp();

      expect(await repo.existsPushUp(), isFalse);
      expect(await repo.existsCurl(), isTrue);
    });

    test('loadCurl returns null and deletes row on corrupt JSON', () async {
      await db.insert('profiles', <String, Object?>{
        'profile_key': SqliteProfileRepository.curlKey,
        'profile_json': 'not valid json {{{',
        'schema_version': 1,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });

      expect(await repo.loadCurl(), isNull);
      expect(
        await repo.existsCurl(),
        isFalse,
        reason: 'corrupt row must be deleted so next save is a clean insert',
      );
      expect(
        TelemetryLog.instance.entries.any(
          (e) => e.tag == 'schema.migration_failed',
        ),
        isTrue,
      );
    });

    test(
      'loadCurl returns null and deletes row on schemaVersion mismatch',
      () async {
        await db.insert('profiles', <String, Object?>{
          'profile_key': SqliteProfileRepository.curlKey,
          'profile_json': jsonEncode(<String, Object?>{
            'schemaVersion': 999,
            'userId': 'local_user',
            'createdAt': DateTime.now().toIso8601String(),
            'lastUsedAt': DateTime.now().toIso8601String(),
            'buckets': <Map<String, dynamic>>[],
          }),
          'schema_version': 1,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        });

        expect(await repo.loadCurl(), isNull);
        expect(await repo.existsCurl(), isFalse);
      },
    );
  });

  group('InMemoryProfileRepository', () {
    test('starts empty, accepts save, returns deep copy on load', () async {
      final repo = InMemoryProfileRepository();
      expect(await repo.loadCurl(), isNull);

      final p = CurlRomProfile()
        ..upsertBucket(
          RomBucket(
            side: ProfileSide.left,
            view: CurlCameraView.front,
            observedMinAngle: 60,
            observedMaxAngle: 165,
            sampleCount: 3,
          ),
        );
      await repo.saveCurl(p);

      final loaded = (await repo.loadCurl())!;
      expect(
        identical(loaded, p),
        isFalse,
        reason: 'must return independent copy',
      );
      expect(
        loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!.sampleCount,
        3,
      );
    });

    test('resetCurl clears stored profile', () async {
      final repo = InMemoryProfileRepository();
      await repo.saveCurl(CurlRomProfile());
      expect(await repo.existsCurl(), isTrue);
      await repo.resetCurl();
      expect(await repo.existsCurl(), isFalse);
    });

    test('stores push-up profile independently', () async {
      final repo = InMemoryProfileRepository();
      final p = PushUpRomProfile.calibrated(topAngle: 168, bottomAngle: 88);
      await repo.savePushUp(p);

      final loaded = (await repo.loadPushUp())!;
      expect(loaded.topAngle, 168);
      expect(loaded.bottomAngle, 88);
      expect(await repo.existsCurl(), isFalse);
      expect(await repo.existsPushUp(), isTrue);
    });
  });
}
