import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_form_thresholds.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('SquatFormThresholds', () {
    test(
      'defaults.leanWarnDegBodyweight matches kSquatLeanWarnDegBodyweight',
      () {
        expect(
          SquatFormThresholds.defaults.leanWarnDegBodyweight,
          kSquatLeanWarnDegBodyweight,
        );
      },
    );

    test('defaults.leanWarnDegHBBS matches kSquatLeanWarnDegHBBS', () {
      expect(
        SquatFormThresholds.defaults.leanWarnDegHBBS,
        kSquatLeanWarnDegHBBS,
      );
    });

    test('defaults.longFemurLeanBoost matches kSquatLongFemurLeanBoost', () {
      expect(
        SquatFormThresholds.defaults.longFemurLeanBoost,
        kSquatLongFemurLeanBoost,
      );
    });

    test('defaults.kneeShiftWarnRatio matches kSquatKneeShiftWarnRatio', () {
      expect(
        SquatFormThresholds.defaults.kneeShiftWarnRatio,
        kSquatKneeShiftWarnRatio,
      );
    });

    test('defaults.heelLiftWarnRatio matches kSquatHeelLiftWarnRatio', () {
      expect(
        SquatFormThresholds.defaults.heelLiftWarnRatio,
        kSquatHeelLiftWarnRatio,
      );
    });

    test(
      'leanWarnFor bodyweight without longFemur == kSquatLeanWarnDegBodyweight',
      () {
        expect(
          SquatFormThresholds.defaults.leanWarnFor(SquatVariant.bodyweight),
          kSquatLeanWarnDegBodyweight,
        );
      },
    );

    test(
      'leanWarnFor bodyweight with longFemur == kSquatLeanWarnDegBodyweight + kSquatLongFemurLeanBoost',
      () {
        expect(
          SquatFormThresholds.defaults.leanWarnFor(
            SquatVariant.bodyweight,
            longFemur: true,
          ),
          kSquatLeanWarnDegBodyweight + kSquatLongFemurLeanBoost,
        );
      },
    );

    test(
      'leanWarnFor highBarBackSquat without longFemur == kSquatLeanWarnDegHBBS',
      () {
        expect(
          SquatFormThresholds.defaults.leanWarnFor(
            SquatVariant.highBarBackSquat,
          ),
          kSquatLeanWarnDegHBBS,
        );
      },
    );

    test(
      'leanWarnFor highBarBackSquat with longFemur == kSquatLeanWarnDegHBBS + kSquatLongFemurLeanBoost',
      () {
        expect(
          SquatFormThresholds.defaults.leanWarnFor(
            SquatVariant.highBarBackSquat,
            longFemur: true,
          ),
          kSquatLeanWarnDegHBBS + kSquatLongFemurLeanBoost,
        );
      },
    );

    test('all fields > 0', () {
      const t = SquatFormThresholds.defaults;
      expect(t.leanWarnDegBodyweight, greaterThan(0));
      expect(t.leanWarnDegHBBS, greaterThan(0));
      expect(t.longFemurLeanBoost, greaterThan(0));
      expect(t.kneeShiftWarnRatio, greaterThan(0));
      expect(t.heelLiftWarnRatio, greaterThan(0));
    });
  });
}
