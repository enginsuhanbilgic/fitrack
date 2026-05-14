import 'package:fitrack/core/curl_form_audit_defaults.dart';
import 'package:fitrack/core/form_thresholds.dart';
import 'package:fitrack/core/squat_form_audit_defaults.dart';
import 'package:fitrack/core/squat_form_thresholds.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/form_auditor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Closes the safety-inversion hole (Sensitivity vs Form Audit doctrine,
/// 2026-05-14, PR A).
///
/// Pre-2026-05-14 a `FormThresholds.forSensitivity(FeedbackSensitivity)` /
/// `SquatFormThresholds.forSensitivity(FeedbackSensitivity)` factory existed
/// and returned tighter gates on `high` than on `medium` — so users who
/// picked the *gentler* tier got *weaker* form warnings. The factory is
/// removed in this PR. This test asserts the doctrine in two ways:
///
/// 1. **Source identity (cheap)** — the canonical fixed instances
///    ([FormThresholds.medium] / [SquatFormThresholds.defaults]) match the
///    new defaults files field-by-field. Catches a future repointing of the
///    builder onto a different constants source.
/// 2. **Behavioral equivalence (the load-bearing assertion)** — the
///    [FormAuditor] entry points still accept a `sensitivity` parameter (it
///    drives ROM tier resolution, NOT form audit). For form-error criteria
///    specifically, the audit verdict for the same rep MUST be identical
///    across `high` and `medium`. If a future PR reintroduces a tier branch
///    on form audit (resurrecting `forSensitivity` or routing
///    `sensitivity` into the form-threshold lookup), one of these reps will
///    flip its verdict between tiers and the test will fail.
void main() {
  group(
    'FormThresholds.medium — source identity with CurlFormAuditDefaults',
    () {
      test('field-by-field equality with CurlFormAuditDefaults', () {
        const t = FormThresholds.medium;
        expect(t.swingThreshold, CurlFormAuditDefaults.swingThreshold);
        expect(
          t.torsoLeanThresholdDeg,
          CurlFormAuditDefaults.torsoLeanThresholdDeg,
        );
        expect(
          t.backLeanThresholdDeg,
          CurlFormAuditDefaults.backLeanThresholdDeg,
        );
        expect(t.shrugThreshold, CurlFormAuditDefaults.shrugThreshold);
        expect(t.driftThreshold, CurlFormAuditDefaults.driftThreshold);
        expect(t.elbowRiseThreshold, CurlFormAuditDefaults.elbowRiseThreshold);
      });
    },
  );

  group(
    'SquatFormThresholds.defaults — source identity with SquatFormAuditDefaults',
    () {
      test('field-by-field equality with SquatFormAuditDefaults', () {
        const t = SquatFormThresholds.defaults;
        expect(
          t.leanWarnDegBodyweight,
          SquatFormAuditDefaults.leanWarnDegBodyweight,
        );
        expect(t.leanWarnDegHBBS, SquatFormAuditDefaults.leanWarnDegHBBS);
        expect(t.longFemurLeanBoost, SquatFormAuditDefaults.longFemurLeanBoost);
        expect(t.kneeShiftWarnRatio, SquatFormAuditDefaults.kneeShiftWarnRatio);
        expect(t.heelLiftWarnRatio, SquatFormAuditDefaults.heelLiftWarnRatio);
      });
    },
  );

  // ── Behavioral equivalence (the doctrine guard) ────────────────────────
  // Run real audits against the same rep at every FeedbackSensitivity tier;
  // assert form-error verdicts are identical across tiers. ROM verdicts are
  // free to differ (sensitivity legitimately drives ROM tier resolution),
  // so we evaluate ONLY criteria sourced from form thresholds.
  group('FormAuditor — form-error verdicts are tier-independent', () {
    const auditor = FormAuditor();

    SquatRepMetrics makeRep({
      double? leanDeg,
      double? kneeShiftRatio,
      double? heelLiftRatio,
    }) => SquatRepMetrics(
      repIndex: 0,
      quality: 1,
      leanDeg: leanDeg,
      kneeShiftRatio: kneeShiftRatio,
      heelLiftRatio: heelLiftRatio,
      minKneeAngle: null,
      maxKneeAngle: null,
    );

    int firedFor(
      String criterionName,
      SquatRepMetrics rep,
      FeedbackSensitivity sensitivity,
    ) {
      final audit = auditor.auditSquat(
        squatRepMetrics: [rep],
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        sensitivity: sensitivity,
      );
      return audit.perCriterion
          .firstWhere((c) => c.name == criterionName)
          .fired;
    }

    test('squat lean fires identically across all sensitivity tiers', () {
      // Fixed gate (bodyweight, no long-femur) is 45°. A 46° rep MUST fire
      // on every tier; a 44° rep MUST pass on every tier. Re-introducing a
      // tier branch (e.g. high=42°) would flip the 44° verdict on high.
      final firingRep = makeRep(leanDeg: 46);
      final passingRep = makeRep(leanDeg: 44);
      for (final sensitivity in FeedbackSensitivity.values) {
        expect(
          firedFor('Forward lean', firingRep, sensitivity),
          1,
          reason: 'Tier $sensitivity: 46° must fire on fixed 45° gate.',
        );
        expect(
          firedFor('Forward lean', passingRep, sensitivity),
          0,
          reason:
              'Tier $sensitivity: 44° must pass on fixed 45° gate. A '
              'regression to a tier-keyed lookup would tighten High to 42° '
              'and fire here.',
        );
      }
    });

    test('squat knee-shift fires identically across all sensitivity tiers', () {
      // Fixed gate is 0.30. A re-coupled high tier would tighten to 0.27.
      final firingRep = makeRep(kneeShiftRatio: 0.31);
      final passingRep = makeRep(kneeShiftRatio: 0.29);
      for (final sensitivity in FeedbackSensitivity.values) {
        expect(
          firedFor('Knee shift', firingRep, sensitivity),
          1,
          reason: 'Tier $sensitivity: 0.31 must fire on fixed 0.30 gate.',
        );
        expect(
          firedFor('Knee shift', passingRep, sensitivity),
          0,
          reason: 'Tier $sensitivity: 0.29 must pass on fixed 0.30 gate.',
        );
      }
    });

    test('squat heel-lift fires identically across all sensitivity tiers', () {
      // Fixed gate is 0.03.
      final firingRep = makeRep(heelLiftRatio: 0.031);
      final passingRep = makeRep(heelLiftRatio: 0.029);
      for (final sensitivity in FeedbackSensitivity.values) {
        expect(
          firedFor('Heel lift', firingRep, sensitivity),
          1,
          reason: 'Tier $sensitivity: 0.031 must fire on fixed 0.03 gate.',
        );
        expect(
          firedFor('Heel lift', passingRep, sensitivity),
          0,
          reason: 'Tier $sensitivity: 0.029 must pass on fixed 0.03 gate.',
        );
      }
    });
  });
}
