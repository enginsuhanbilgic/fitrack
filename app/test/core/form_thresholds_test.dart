import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/form_thresholds.dart';

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

    test('all fields > 0', () {
      const t = FormThresholds.medium;
      expect(t.swingThreshold, greaterThan(0));
      expect(t.torsoLeanThresholdDeg, greaterThan(0));
      expect(t.backLeanThresholdDeg, greaterThan(0));
      expect(t.shrugThreshold, greaterThan(0));
      expect(t.driftThreshold, greaterThan(0));
      expect(t.elbowRiseThreshold, greaterThan(0));
    });
  });
}
