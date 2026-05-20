import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/curl_form_audit_defaults.dart';
import 'package:fitrack/core/squat_form_audit_defaults.dart';

/// Asserts every constant in [CurlFormAuditDefaults] and [SquatFormAuditDefaults]
/// matches the previous `medium`-tier value (i.e. the unmodified `k*` constants
/// in `constants.dart`).
///
/// Demonstrates the doctrine claim: medium users see ZERO behavior change after
/// the Sensitivity vs Form Audit decoupling (2026-05-14). High users get a
/// marginal relaxation matching the doctrine's intent — that observation is
/// covered by `form_audit_independence_test.dart`.
void main() {
  group('CurlFormAuditDefaults — fixed values match previous medium tier', () {
    test('swingThreshold == kSwingThreshold', () {
      expect(CurlFormAuditDefaults.swingThreshold, kSwingThreshold);
    });
    test('torsoLeanThresholdDeg == kTorsoLeanThresholdDeg', () {
      expect(
        CurlFormAuditDefaults.torsoLeanThresholdDeg,
        kTorsoLeanThresholdDeg,
      );
    });
    test('backLeanThresholdDeg == kBackLeanThresholdDeg', () {
      expect(CurlFormAuditDefaults.backLeanThresholdDeg, kBackLeanThresholdDeg);
    });
    test('shrugThreshold == kShrugThreshold', () {
      expect(CurlFormAuditDefaults.shrugThreshold, kShrugThreshold);
    });
    test('driftThreshold == kDriftThreshold', () {
      expect(CurlFormAuditDefaults.driftThreshold, kDriftThreshold);
    });
  });

  group('SquatFormAuditDefaults — fixed values match previous medium tier', () {
    test('leanWarnDegBodyweight == kSquatLeanWarnDegBodyweight', () {
      expect(
        SquatFormAuditDefaults.leanWarnDegBodyweight,
        kSquatLeanWarnDegBodyweight,
      );
    });
    test('leanWarnDegHBBS == kSquatLeanWarnDegHBBS', () {
      expect(SquatFormAuditDefaults.leanWarnDegHBBS, kSquatLeanWarnDegHBBS);
    });
    test('longFemurLeanBoost == kSquatLongFemurLeanBoost', () {
      expect(
        SquatFormAuditDefaults.longFemurLeanBoost,
        kSquatLongFemurLeanBoost,
      );
    });
    test('kneeShiftWarnRatio == kSquatKneeShiftWarnRatio', () {
      expect(
        SquatFormAuditDefaults.kneeShiftWarnRatio,
        kSquatKneeShiftWarnRatio,
      );
    });
    test('heelLiftWarnRatio == kSquatHeelLiftWarnRatio', () {
      expect(SquatFormAuditDefaults.heelLiftWarnRatio, kSquatHeelLiftWarnRatio);
    });
  });
}
