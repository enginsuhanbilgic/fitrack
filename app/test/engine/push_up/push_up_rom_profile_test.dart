import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/push_up/push_up_rom_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PushUpRomProfile', () {
    test('validates realistic top and bottom brackets', () {
      expect(
        () => PushUpRomProfile.calibrated(topAngle: 130, bottomAngle: 80),
        throwsStateError,
      );
      expect(
        () => PushUpRomProfile.calibrated(topAngle: 170, bottomAngle: 155),
        throwsStateError,
      );
      expect(
        () => PushUpRomProfile.calibrated(topAngle: 170, bottomAngle: 82),
        returnsNormally,
      );
    });

    test('derives ordered personalized thresholds with margins', () {
      final thresholds = PushUpRomProfile.calibrated(
        topAngle: 170,
        bottomAngle: 82,
      ).thresholds;

      expect(thresholds.startAngle, lessThanOrEqualTo(kPushUpEndAngle));
      expect(thresholds.bottomAngle, closeTo(90, 0.01));
      expect(thresholds.shallowRepMaxAngle, closeTo(127.4, 0.01));
      expect(thresholds.bottomAngle, lessThan(thresholds.shallowRepMaxAngle));
      expect(thresholds.shallowRepMaxAngle, lessThan(thresholds.startAngle));
      expect(thresholds.endAngle, greaterThanOrEqualTo(thresholds.startAngle));
    });

    test(
      'restricted ROM profile still produces reachable count thresholds',
      () {
        final profile = PushUpRomProfile.calibrated(
          topAngle: 150,
          bottomAngle: 130,
        );
        final thresholds = profile.thresholds;

        expect(thresholds.startAngle, lessThan(150));
        expect(thresholds.endAngle, lessThan(150));
        expect(thresholds.bottomAngle, greaterThan(130));
        expect(thresholds.bottomAngle, lessThan(thresholds.shallowRepMaxAngle));
        expect(thresholds.shallowRepMaxAngle, lessThan(thresholds.startAngle));
        expect(thresholds.startAngle, lessThanOrEqualTo(thresholds.endAngle));
      },
    );

    test('round-trips JSON and rejects schema mismatch', () {
      final profile = PushUpRomProfile.calibrated(
        topAngle: 168,
        bottomAngle: 86,
      );
      final loaded = PushUpRomProfile.fromJson(profile.toJson());

      expect(loaded.topAngle, 168);
      expect(loaded.bottomAngle, 86);
      expect(
        () => PushUpRomProfile.fromJson(<String, dynamic>{
          ...profile.toJson(),
          'schemaVersion': 999,
        }),
        throwsStateError,
      );
    });
  });

  group('PushUpRomProfile — v2 schema (2026-05-15)', () {
    test('v1 fixture deserialises with null v2 fields and isLegacyV1=true', () {
      final v1 = <String, dynamic>{
        'schemaVersion': 1,
        'topAngle': 168.0,
        'bottomAngle': 86.0,
        'sampleCount': 3,
        'createdAt': '2026-04-01T10:00:00.000Z',
        'lastUpdated': '2026-04-01T10:00:00.000Z',
      };
      final loaded = PushUpRomProfile.fromJson(v1);

      expect(loaded.topAngle, 168);
      expect(loaded.bottomAngle, 86);
      expect(loaded.calibrationRepCount, isNull);
      expect(loaded.lastAppliedRepAt, isNull);
      expect(loaded.isLegacyV1, isTrue);
    });

    test('v2 fixture round-trips cleanly through toJson/fromJson', () {
      final original = PushUpRomProfile.calibrated(
        topAngle: 168,
        bottomAngle: 86,
        calibrationRepCount: 5,
      );
      final loaded = PushUpRomProfile.fromJson(original.toJson());

      expect(loaded.calibrationRepCount, 5);
      expect(loaded.lastAppliedRepAt, isNull);
      // Fresh v2 records produced by `calibrated()` are NOT legacy — the
      // factory writes schemaVersion=2 into toJson, so fromJson sees v2.
      expect(loaded.isLegacyV1, isFalse);
    });

    test('toJson omits null v2 fields to keep payloads small', () {
      final profile = PushUpRomProfile.calibrated(
        topAngle: 168,
        bottomAngle: 86,
        // No calibrationRepCount supplied.
      );
      final json = profile.toJson();

      expect(json.containsKey('calibrationRepCount'), isFalse);
      expect(json.containsKey('lastAppliedRepAt'), isFalse);
      expect(json['schemaVersion'], 2);
    });

    test('isLegacyV1 is false on fresh `calibrated()` factory output', () {
      final fresh = PushUpRomProfile.calibrated(topAngle: 168, bottomAngle: 86);
      expect(fresh.isLegacyV1, isFalse);
    });
  });
}
