/// Pure-Dart unit tests for [FormAuditor.auditSquat] — Squat Pipeline
/// Overhaul Part 4 (audit upgrade).
///
/// Coverage focuses on the Part 4 acceptance criteria:
///   * Tier-priority ROM resolution (Tier 1 profile → Tier 2 auto-cal →
///     Tier 3 sensitivity-modified cold start).
///   * Real-angle depth grading (replaces the `quality < 0.85` proxy).
///   * Sensitivity propagation through form-error thresholds (NOT
///     always-high).
///   * Graceful "not graded" handling for pre-v9 reconstructed sessions
///     (`minKneeAngle == null`).
///   * Hip-lead criterion sourced from session-level error counts.
///   * The empty-reps `applicable == false` path.
library;

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/squat_rom_defaults.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/form_auditor.dart';
import 'package:fitrack/engine/squat/squat_rom_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FormAuditor.auditSquat — Part 4 tier-priority + real-depth grading', () {
    const auditor = FormAuditor();

    /// Build a [SquatRepMetrics] with sensible defaults so each test can
    /// override only the field it's testing. Default values are designed to
    /// PASS every criterion at every sensitivity level, so a single
    /// override per test pins exactly one failure mode.
    SquatRepMetrics rep({
      int repIndex = 0,
      double? minKneeAngle = 85.0,
      double? maxKneeAngle = 170.0,
      double? leanDeg = 20.0,
      double? kneeShiftRatio = 0.10,
      double? heelLiftRatio = 0.01,
      double? quality = 1.0,
    }) {
      return SquatRepMetrics(
        repIndex: repIndex,
        quality: quality,
        leanDeg: leanDeg,
        kneeShiftRatio: kneeShiftRatio,
        heelLiftRatio: heelLiftRatio,
        minKneeAngle: minKneeAngle,
        maxKneeAngle: maxKneeAngle,
      );
    }

    CriterionResult criterionByName(FormAudit a, String name) =>
        a.perCriterion.firstWhere((c) => c.name == name);

    test('empty reps → applicable=false', () {
      final audit = auditor.auditSquat(
        squatRepMetrics: const [],
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
      );
      expect(audit.applicable, isFalse);
      expect(audit.notApplicableReason, isNotNull);
      expect(audit.repsTotal, 0);
    });

    // ── Tier 1: personal calibration drives depth grading ─────────────────
    test(
      'Tier 1 — calibrated profile grades depth against bucket.bottomAngle',
      () {
        // Personal bucket: deepest knee 80°, most-extended 175°. With the
        // canonical bottom margin (5°), the effective Tier-1 bottomAngle is
        // 85°. A rep with minKneeAngle=84° passes (84 < 85); a rep with
        // minKneeAngle=86° fires the depth criterion (86 > 85).
        final calibrated = SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 80.0,
            observedMaxKneeAngle: 175.0,
            sampleCount: kSquatCalibrationMinReps,
          ),
        );
        // Sanity guard — if the project changes calibration min reps, the
        // test must be updated alongside.
        expect(calibrated.isCalibrated, isTrue);

        final reps = [
          rep(repIndex: 0, minKneeAngle: 84.0),
          rep(repIndex: 1, minKneeAngle: 86.0),
        ];
        final audit = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
          squatProfile: calibrated,
        );
        final depth = criterionByName(audit, 'Depth');
        expect(depth.evaluated, 2);
        expect(
          depth.fired,
          1,
          reason:
              'Tier 1 effective bottomAngle = 80 + 5 = 85°. Only rep 1 '
              '(86° > 85°) should fail; rep 0 (84° < 85°) passes.',
        );
      },
    );

    // ── Tier 2: auto-cal snapshot drives depth grading ────────────────────
    test('Tier 2 — auto-cal snapshot used when profile is uncalibrated', () {
      // Uncalibrated profile: bucket exists but sampleCount = 0 → isCalibrated
      // is false → Tier 1 declines.
      final emptyProfile = SquatRomProfile();
      expect(emptyProfile.isCalibrated, isFalse);

      // Auto-cal snapshot is the Tier-2 bar. Snapshot's bottomAngle = 92°
      // (intentionally NOT matching any cold-start value so the test pins
      // exactly which tier was consulted).
      const autoCal = SquatRomThresholdSet(
        startAngle: 168,
        bottomAngle: 92,
        endAngle: 165,
      );

      final reps = [
        rep(repIndex: 0, minKneeAngle: 91.0),
        rep(repIndex: 1, minKneeAngle: 93.0),
      ];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        squatProfile: emptyProfile,
        autoCalSnapshot: autoCal,
      );
      final depth = criterionByName(audit, 'Depth');
      expect(
        depth.fired,
        1,
        reason:
            'Tier-2 bottomAngle=92°: rep 0 (91°<92°) passes, rep 1 (93°>92°) fires.',
      );
    });

    // ── Tier 3: cold-start sensitivity fallback ───────────────────────────
    test(
      'Tier 3 — falls through to forSensitivity when no profile / no auto-cal',
      () {
        // Medium sensitivity → bottomAngle = kSquatBottomAngle (90°).
        final reps = [rep(minKneeAngle: 89.0), rep(minKneeAngle: 91.0)];
        final audit = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
        );
        final depth = criterionByName(audit, 'Depth');
        expect(depth.fired, 1);
      },
    );

    test(
      'Tier 3 — HIGH sensitivity tightens depth gate to kSquatBottomAngleHigh',
      () {
        // High-sensitivity bottomAngle = 88°. A rep at 89° passes Medium but
        // fires at High — this test pins that sensitivity is wired into the
        // Tier-3 path.
        final reps = [rep(minKneeAngle: 89.0)];
        final auditHigh = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
          sensitivity: FeedbackSensitivity.high,
        );
        expect(criterionByName(auditHigh, 'Depth').fired, 1);

        final auditMed = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
          // Default sensitivity = Medium.
        );
        expect(criterionByName(auditMed, 'Depth').fired, 0);
      },
    );

    // ── Sensitivity propagation through form-error thresholds ─────────────
    test('sensitivity propagation — lean fires at High but NOT at Medium', () {
      // Bodyweight lean: Medium gate=45°, High gate=42°. A rep at 44°
      // should fire on High but pass on Medium (the 2026-05-13 parity
      // requirement — squat audit must use the user's sensitivity, NOT
      // always-high).
      final reps = [rep(leanDeg: 44.0)];

      final auditMedium = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        sensitivity: FeedbackSensitivity.medium,
      );
      expect(
        criterionByName(auditMedium, 'Forward lean').fired,
        0,
        reason: 'Medium gate=45° — a 44° rep should pass.',
      );

      final auditHigh = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        sensitivity: FeedbackSensitivity.high,
      );
      expect(
        criterionByName(auditHigh, 'Forward lean').fired,
        1,
        reason: 'High gate=42° — a 44° rep should fire.',
      );
    });

    // ── Pre-v9 reconstructed session: depth dropped to "not graded" ───────
    test(
      'pre-v9 session — minKneeAngle=null gracefully drops depth criterion',
      () {
        // Two reps with no minKneeAngle (history reconstruction has only
        // ratios). Other criteria still graded; depth should NOT crash and
        // should be entirely absent from the filtered criterion list (zero
        // evaluable reps → criterion dropped by `filteredCriteria`).
        final reps = [
          rep(minKneeAngle: null, maxKneeAngle: null),
          rep(repIndex: 1, minKneeAngle: null, maxKneeAngle: null),
        ];
        final audit = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
        );
        // Depth criterion should not be reported (zero evaluable reps →
        // dropped from display per the existing "keep card clean" rule).
        final names = audit.perCriterion.map((c) => c.name).toList();
        expect(names, isNot(contains('Depth')));
        // The audit is still applicable because the lean/shift/heel
        // criteria evaluated successfully.
        expect(audit.applicable, isTrue);
        expect(audit.repsEvaluated, 2);
      },
    );

    // ── Hip-lead criterion sourced from error counts ──────────────────────
    test('hip-lead — fire count flows through to the criterion', () {
      final reps = [
        rep(repIndex: 0),
        rep(repIndex: 1),
        rep(repIndex: 2),
        rep(repIndex: 3),
        rep(repIndex: 4),
      ];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        // Simulate rep 3 firing hipLead — count is session-level so the
        // audit only sees the aggregate.
        hipLeadFireCount: 1,
      );
      final hipLead = criterionByName(audit, 'Hip lead');
      expect(hipLead.evaluated, 5);
      expect(hipLead.fired, 1);
    });

    test('hip-lead — fire count clamped to repsTotal (no >100% pass rate)', () {
      // Corrupted error count: 99 fires on a 2-rep session would yield a
      // nonsensical pass rate. The clamp guards against that.
      final reps = [rep(repIndex: 0), rep(repIndex: 1)];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        hipLeadFireCount: 99,
      );
      final hipLead = criterionByName(audit, 'Hip lead');
      expect(hipLead.fired, 2);
      expect(hipLead.fired, lessThanOrEqualTo(hipLead.evaluated));
    });

    test('hip-lead — zero fires still reports criterion '
        '(evaluated = repsTotal)', () {
      // The session graded the absence of hip-lead, so the criterion
      // should show up with fired=0 — not be dropped. This is asymmetric
      // with the depth/lean/shift/heel rules (those drop when there's no
      // data for any rep); hip-lead is a session-aggregate signal whose
      // "no fires" reading is itself a positive grade.
      final reps = [rep(repIndex: 0), rep(repIndex: 1)];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
        // hipLeadFireCount defaults to 0.
      );
      final hipLead = criterionByName(audit, 'Hip lead');
      expect(hipLead.evaluated, 2);
      expect(hipLead.fired, 0);
    });

    // ── Bottom-angle from the calibrated bucket actually drives the gate ──
    test(
      'Tier 1 — only observedMinKneeAngle drives the depth gate, not max',
      () {
        // This test is structured around a rep deliberately placed at the
        // gate boundary so the value of `bottomAngle` is load-bearing
        // (the prior version of this test placed the rep far inside the
        // bucket, which made both bucket variants pass 0 — tautology
        // because the same `fired=0` would appear even if max were
        // accidentally wired into the gate).
        //
        // Bucket A: min=82, max=175 → bottomAngle = 82 + 5 = 87°.
        // Bucket B: min=82, max=160 → bottomAngle = 82 + 5 = 87° (max
        //   differs but min is identical, so the gate is unchanged).
        // Bucket C: min=86, max=175 → bottomAngle = 86 + 5 = 91° (min
        //   shifted shallower, so the gate IS different from A/B).
        //
        // Then we pin pass/fail on each bucket at two rep angles that
        // straddle the A/B gate vs the C gate.
        final pA = SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 82.0,
            observedMaxKneeAngle: 175.0,
            sampleCount: kSquatCalibrationMinReps,
          ),
        );
        final pB = SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 82.0,
            observedMaxKneeAngle: 160.0, // max changed; min unchanged
            sampleCount: kSquatCalibrationMinReps,
          ),
        );
        final pC = SquatRomProfile(
          bucket: SquatRomBucket(
            observedMinKneeAngle: 86.0, // min changed; max unchanged
            observedMaxKneeAngle: 175.0,
            sampleCount: kSquatCalibrationMinReps,
          ),
        );

        FormAudit audit(SquatRomProfile p, double angle) => auditor.auditSquat(
          squatRepMetrics: [rep(minKneeAngle: angle)],
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
          squatProfile: p,
        );

        // Rep at 89° — fails A/B gate (89 > 87°) but PASSES C gate (89 < 91°).
        expect(
          criterionByName(audit(pA, 89), 'Depth').fired,
          1,
          reason: 'Bucket A: 89° > 87° gate → fired.',
        );
        expect(
          criterionByName(audit(pB, 89), 'Depth').fired,
          criterionByName(audit(pA, 89), 'Depth').fired,
          reason:
              'Bucket B differs from A only in observedMaxKneeAngle — depth '
              'must match A exactly. If max accidentally entered the gate, '
              'this would diverge.',
        );
        expect(
          criterionByName(audit(pC, 89), 'Depth').fired,
          0,
          reason:
              'Bucket C: shallower min raises gate to 91° — a 89° rep now '
              'passes. This pins that min IS load-bearing (the gate value '
              'actually changes with min, so the A=B equality above is '
              'meaningful, not tautological).',
        );
      },
    );

    // ── Coverage gap fills (test-quality review follow-up) ────────────────
    test(
      'longFemurLifter=true widens the lean gate by kSquatLongFemurLeanBoost',
      () {
        // A rep with leanDeg=48° passes when the long-femur boost is on
        // (gate=45+5=50°) but fires when off (gate=45°). Defends the
        // `+ longFemurLeanBoost` branch in `SquatFormThresholds.leanWarnFor`.
        final reps = [rep(leanDeg: 48.0)];
        final auditOn = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: true,
          fatigueDetected: false,
        );
        expect(
          criterionByName(auditOn, 'Forward lean').fired,
          0,
          reason: 'Long-femur boost lifts the BW gate to 50°.',
        );
        final auditOff = auditor.auditSquat(
          squatRepMetrics: reps,
          variant: SquatVariant.bodyweight,
          longFemurLifter: false,
          fatigueDetected: false,
        );
        expect(
          criterionByName(auditOff, 'Forward lean').fired,
          1,
          reason: 'Without the boost, the BW gate stays at 45°.',
        );
      },
    );

    test('HBBS variant uses the wider lean gate (50° vs bodyweight 45°)', () {
      // A rep at 47°: passes HBBS (gate=50°), fires bodyweight (gate=45°).
      // Pins the `switch (variant)` in `SquatFormThresholds.leanWarnFor`.
      final reps = [rep(leanDeg: 47.0)];
      final auditHbbs = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.highBarBackSquat,
        longFemurLifter: false,
        fatigueDetected: false,
      );
      expect(criterionByName(auditHbbs, 'Forward lean').fired, 0);
      final auditBw = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
      );
      expect(criterionByName(auditBw, 'Forward lean').fired, 1);
    });

    test('knee-shift criterion fires when ratio exceeds threshold', () {
      // Medium gate kSquatKneeShiftWarnRatio = 0.30. A rep at 0.42 fires;
      // a rep at 0.20 passes. Defends the `kneeShiftRatio` branch — without
      // this, a sign-flip on `> strictForm.kneeShiftWarnRatio` would slip
      // through the suite.
      final reps = [
        rep(repIndex: 0, kneeShiftRatio: 0.20),
        rep(repIndex: 1, kneeShiftRatio: 0.42),
      ];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
      );
      final c = criterionByName(audit, 'Knee shift');
      expect(c.evaluated, 2);
      expect(c.fired, 1);
    });

    test('heel-lift criterion fires when ratio exceeds threshold', () {
      // Medium gate kSquatHeelLiftWarnRatio = 0.03. A rep at 0.05 fires;
      // a rep at 0.01 passes. Same defense as knee-shift.
      final reps = [
        rep(repIndex: 0, heelLiftRatio: 0.01),
        rep(repIndex: 1, heelLiftRatio: 0.05),
      ];
      final audit = auditor.auditSquat(
        squatRepMetrics: reps,
        variant: SquatVariant.bodyweight,
        longFemurLifter: false,
        fatigueDetected: false,
      );
      final c = criterionByName(audit, 'Heel lift');
      expect(c.evaluated, 2);
      expect(c.fired, 1);
    });
  });
}
