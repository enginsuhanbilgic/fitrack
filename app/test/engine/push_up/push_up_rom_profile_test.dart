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
}
