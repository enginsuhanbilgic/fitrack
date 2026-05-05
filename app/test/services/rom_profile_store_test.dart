import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';
import 'package:fitrack/services/rom_profile_store.dart';

void main() {
  late Directory tmp;
  late FileRomProfileStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fitrack_store_test_');
    store = FileRomProfileStore(docsDirProvider: () async => tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('FileRomProfileStore', () {
    test('load returns null when file does not exist', () async {
      expect(await store.load(), isNull);
      expect(await store.exists(), isFalse);
    });

    test('save then load round-trips a profile faithfully', () async {
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
      await store.save(p);

      final loaded = (await store.load())!;
      expect(loaded.userId, 'local_user');
      final b = loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!;
      expect(b.observedMinAngle, 60);
      expect(b.observedMaxAngle, 165);
      expect(b.sampleCount, 5);
    });

    test('save uses .tmp + rename — no .tmp file lingers', () async {
      final p = CurlRomProfile()
        ..upsertBucket(RomBucket.empty(ProfileSide.left, CurlCameraView.front));
      await store.save(p);

      final dir = Directory('${tmp.path}/${FileRomProfileStore.subdir}');
      final tmpFiles = dir.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.tmp'),
      );
      expect(tmpFiles, isEmpty);
    });

    test('reset deletes the file', () async {
      final p = CurlRomProfile()
        ..upsertBucket(RomBucket.empty(ProfileSide.left, CurlCameraView.front));
      await store.save(p);
      expect(await store.exists(), isTrue);

      await store.reset();
      expect(await store.exists(), isFalse);
    });

    test('reset on a missing file is a no-op (does not throw)', () async {
      await expectLater(store.reset(), completes);
    });

    test('load returns null and deletes the file on schema mismatch', () async {
      // Manually write a file with the wrong schema version.
      final dir = Directory('${tmp.path}/${FileRomProfileStore.subdir}')
        ..createSync(recursive: true);
      final f = File('${dir.path}/${FileRomProfileStore.filename}');
      f.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 999,
          'userId': 'local_user',
          'createdAt': DateTime.now().toIso8601String(),
          'lastUsedAt': DateTime.now().toIso8601String(),
          'buckets': <Map<String, dynamic>>[],
        }),
      );

      expect(await store.load(), isNull);
      expect(f.existsSync(), isFalse);
    });

    test('load returns null and deletes the file on corrupt JSON', () async {
      final dir = Directory('${tmp.path}/${FileRomProfileStore.subdir}')
        ..createSync(recursive: true);
      final f = File('${dir.path}/${FileRomProfileStore.filename}');
      f.writeAsStringSync('not valid json {{{');

      expect(await store.load(), isNull);
      expect(f.existsSync(), isFalse);
    });

    test('overwriting an existing profile uses atomic replace', () async {
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
      await store.save(p1);

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
      await store.save(p2);

      final loaded = (await store.load())!;
      final b = loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!;
      expect(b.observedMinAngle, 50);
      expect(b.observedMaxAngle, 170);
      expect(b.sampleCount, 9);
    });
  });

  group('InMemoryRomProfileStore', () {
    test('starts empty, accepts save, returns deep copy on load', () async {
      final store = InMemoryRomProfileStore();
      expect(await store.load(), isNull);

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
      await store.save(p);

      final loaded = (await store.load())!;
      expect(
        identical(loaded, p),
        isFalse,
        reason: 'load must return an independent copy',
      );
      expect(
        loaded.bucketFor(ProfileSide.left, CurlCameraView.front)!.sampleCount,
        3,
      );
    });
  });
}
