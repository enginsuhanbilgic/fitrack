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

  group('SquatFormThresholds.forSensitivity', () {
    test('medium == defaults (zero delta)', () {
      final m = SquatFormThresholds.forSensitivity(FeedbackSensitivity.medium);
      expect(m.leanWarnDegBodyweight, kSquatLeanWarnDegBodyweight);
      expect(m.leanWarnDegHBBS, kSquatLeanWarnDegHBBS);
      expect(m.kneeShiftWarnRatio, kSquatKneeShiftWarnRatio);
      expect(m.heelLiftWarnRatio, kSquatHeelLiftWarnRatio);
      expect(m.longFemurLeanBoost, kSquatLongFemurLeanBoost);
    });

    test('high produces tighter (smaller) thresholds than medium', () {
      final high = SquatFormThresholds.forSensitivity(FeedbackSensitivity.high);
      final med = SquatFormThresholds.forSensitivity(
        FeedbackSensitivity.medium,
      );
      expect(high.leanWarnDegBodyweight, lessThan(med.leanWarnDegBodyweight));
      expect(high.leanWarnDegHBBS, lessThan(med.leanWarnDegHBBS));
      expect(high.kneeShiftWarnRatio, lessThan(med.kneeShiftWarnRatio));
      expect(high.heelLiftWarnRatio, lessThan(med.heelLiftWarnRatio));
    });

    test('high lean delta is exactly −3°', () {
      final high = SquatFormThresholds.forSensitivity(FeedbackSensitivity.high);
      expect(
        high.leanWarnDegBodyweight,
        closeTo(kSquatLeanWarnDegBodyweight - 3.0, 1e-9),
      );
    });

    test('longFemurLeanBoost is unchanged across all sensitivity levels', () {
      for (final s in FeedbackSensitivity.values) {
        expect(
          SquatFormThresholds.forSensitivity(s).longFemurLeanBoost,
          kSquatLongFemurLeanBoost,
        );
      }
    });

    test('all fields > 0 for all sensitivity levels', () {
      for (final s in FeedbackSensitivity.values) {
        final t = SquatFormThresholds.forSensitivity(s);
        expect(
          t.leanWarnDegBodyweight,
          greaterThan(0),
          reason: '$s leanWarnDegBodyweight',
        );
        expect(t.leanWarnDegHBBS, greaterThan(0), reason: '$s leanWarnDegHBBS');
        expect(
          t.kneeShiftWarnRatio,
          greaterThan(0),
          reason: '$s kneeShiftWarnRatio',
        );
        expect(
          t.heelLiftWarnRatio,
          greaterThan(0),
          reason: '$s heelLiftWarnRatio',
        );
      }
    });
  });
}
