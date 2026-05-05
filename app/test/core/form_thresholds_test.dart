import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/form_thresholds.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('FormThresholds', () {
    test('medium constant matches hard-coded constants exactly', () {
      const m = FormThresholds.medium;
      expect(m.swingThreshold, kSwingThreshold);
      expect(m.torsoLeanThresholdDeg, kTorsoLeanThresholdDeg);
      expect(m.backLeanThresholdDeg, kBackLeanThresholdDeg);
      expect(m.shrugThreshold, kShrugThreshold);
      expect(m.driftThreshold, kDriftThreshold);
      expect(m.elbowRiseThreshold, kElbowRiseThreshold);
    });

    test('forSensitivity(medium) equals medium constant', () {
      final built = FormThresholds.forSensitivity(CurlSensitivity.medium);
      const m = FormThresholds.medium;
      expect(built.swingThreshold, m.swingThreshold);
      expect(built.torsoLeanThresholdDeg, m.torsoLeanThresholdDeg);
      expect(built.backLeanThresholdDeg, m.backLeanThresholdDeg);
      expect(built.shrugThreshold, m.shrugThreshold);
      expect(built.driftThreshold, m.driftThreshold);
      expect(built.elbowRiseThreshold, m.elbowRiseThreshold);
    });

    test('high multiplies all fields by 0.75', () {
      const multiplier = 0.75;
      final h = FormThresholds.forSensitivity(CurlSensitivity.high);
      expect(h.swingThreshold, closeTo(kSwingThreshold * multiplier, 1e-9));
      expect(
        h.torsoLeanThresholdDeg,
        closeTo(kTorsoLeanThresholdDeg * multiplier, 1e-9),
      );
      expect(
        h.backLeanThresholdDeg,
        closeTo(kBackLeanThresholdDeg * multiplier, 1e-9),
      );
      expect(h.shrugThreshold, closeTo(kShrugThreshold * multiplier, 1e-9));
      expect(h.driftThreshold, closeTo(kDriftThreshold * multiplier, 1e-9));
      expect(
        h.elbowRiseThreshold,
        closeTo(kElbowRiseThreshold * multiplier, 1e-9),
      );
    });

    test('all fields > 0 for all sensitivities', () {
      for (final s in CurlSensitivity.values) {
        final t = FormThresholds.forSensitivity(s);
        expect(
          t.swingThreshold,
          greaterThan(0),
          reason: 'swingThreshold for $s',
        );
        expect(
          t.torsoLeanThresholdDeg,
          greaterThan(0),
          reason: 'torsoLeanThresholdDeg for $s',
        );
        expect(
          t.backLeanThresholdDeg,
          greaterThan(0),
          reason: 'backLeanThresholdDeg for $s',
        );
        expect(
          t.shrugThreshold,
          greaterThan(0),
          reason: 'shrugThreshold for $s',
        );
        expect(
          t.driftThreshold,
          greaterThan(0),
          reason: 'driftThreshold for $s',
        );
        expect(
          t.elbowRiseThreshold,
          greaterThan(0),
          reason: 'elbowRiseThreshold for $s',
        );
      }
    });

    test('high is stricter than medium', () {
      final high = FormThresholds.forSensitivity(CurlSensitivity.high);
      final med = FormThresholds.forSensitivity(CurlSensitivity.medium);

      expect(high.swingThreshold, lessThan(med.swingThreshold));
      expect(high.shrugThreshold, lessThan(med.shrugThreshold));
    });
  });
}
