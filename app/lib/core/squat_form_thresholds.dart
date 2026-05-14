/// ═══════════════════════════════════════════════════════════════════
/// Injectable squat form-error thresholds — literature-anchored.
/// ═══════════════════════════════════════════════════════════════════
///
/// Unlike `curl_rom_defaults.dart` (curl, derived from live in-app
/// diagnostic-session telemetry), these values are NOT derived from
/// recorded sessions. FiTrack does not yet run a telemetry-derivation
/// pipeline for squat; the values come from the master research spec
/// (`docs/squat/SQUAT_MASTER_SPEC.md`) which synthesizes two independent
/// deep-research reports.
///
/// **NOT tier-dependent** (Sensitivity vs Form Audit doctrine, 2026-05-14).
/// Pre-2026-05-14 a `SquatFormThresholds.forSensitivity(FeedbackSensitivity)`
/// factory tightened gates on `high` (lean −3°, knee-shift −0.03, heel-lift
/// −0.005) — that produced a safety inversion where users on the *gentler*
/// tier got *weaker* form warnings. The factory is removed; callers use
/// [SquatFormThresholds.defaults] (the canonical fixed instance, sourced
/// from [SquatFormAuditDefaults]).
///
/// STATUS LEGEND
/// ─────────────
///   ✅ literature-anchored, safe to ship as v1
///   ⚠️ literature-anchored with measurement-noise margin
///   (empirical-TBD) engineering estimate; promote with care
///
/// Per-field provenance:
///   ⚠️ Lean (`leanWarnDegBodyweight`, `leanWarnDegHBBS`) —
///       Glassbrook 2017 + Straub & Powers 2024, +5° margin.
///       CI [40, 50] for bodyweight; CI [45, 55] for HBBS.
///   (empirical-TBD) Forward knee shift (`kneeShiftWarnRatio`) — Hartmann 2013.
///       Research docs disagreed 3× (Claude 0.30, Google 0.10). CI [0.10, 0.35].
///   (empirical-TBD) Heel lift (`heelLiftWarnRatio`) — Macrum 2012,
///       engineering estimate. CI [0.02, 0.04].
///   ✅ Long-femur lean boost (`longFemurLeanBoost`) — applied at the
///       call site (`SquatFormAnalyzer`) when the "Tall lifter" Settings
///       toggle is on, so this class stays free of that user-preference state.
///
/// CITATIONS
/// ─────────
///   Glassbrook, D.J., Helms, E.R., Brown, S.R., & Storey, A.G. (2017).
///     A review of the biomechanical differences between the high-bar
///     and low-bar back-squat. JSCR 31(9), 2618–2634.
///   Straub, R.K., & Powers, C.M. (2024). A biomechanical review of
///     the squat exercise. IJSPT 19(4), 491–501.
///   Macrum, E., Bell, D.R., Boling, M., Lewek, M., & Padua, D. (2012).
///     Effect of limiting ankle-DF ROM on lower extremity kinematics
///     and muscle-activation patterns during a squat. JSR 21(2),
///     144–150.
///   Hartmann, H., Wirth, K., Klusemann, M., Dalic, J., Matuschek, C.,
///     & Schmidtbleicher, D. (2013). Influence of squatting depth on
///     jumping performance. JSCR 26(12), 3243–3261.
/// ═══════════════════════════════════════════════════════════════════
library;

import 'squat_form_audit_defaults.dart';
import 'types.dart';

/// Injectable form-error thresholds for [SquatFormAnalyzer].
///
/// Mirrors [FormThresholds] for biceps curl. Decouples [SquatFormAnalyzer]
/// from global k* constants so tests can inject different values for
/// boundary-condition assertions. The numeric values live in
/// [SquatFormAuditDefaults] (the doctrine-anchored source of truth);
/// this class adds the variant + long-femur dispatch.
class SquatFormThresholds {
  const SquatFormThresholds({
    required this.leanWarnDegBodyweight,
    required this.leanWarnDegHBBS,
    required this.longFemurLeanBoost,
    required this.kneeShiftWarnRatio,
    required this.heelLiftWarnRatio,
  });

  final double leanWarnDegBodyweight;
  final double leanWarnDegHBBS;
  final double longFemurLeanBoost;
  final double kneeShiftWarnRatio;
  final double heelLiftWarnRatio;

  /// Canonical fixed instance. Sourced from [SquatFormAuditDefaults] so the
  /// values have one home (the defaults file) and one consumer surface (this
  /// class). The single API replaces the deleted `forSensitivity` factory.
  static const SquatFormThresholds defaults = SquatFormThresholds(
    leanWarnDegBodyweight: SquatFormAuditDefaults.leanWarnDegBodyweight,
    leanWarnDegHBBS: SquatFormAuditDefaults.leanWarnDegHBBS,
    longFemurLeanBoost: SquatFormAuditDefaults.longFemurLeanBoost,
    kneeShiftWarnRatio: SquatFormAuditDefaults.kneeShiftWarnRatio,
    heelLiftWarnRatio: SquatFormAuditDefaults.heelLiftWarnRatio,
  );

  /// Effective lean threshold for a given variant + long-femur flag.
  double leanWarnFor(SquatVariant variant, {bool longFemur = false}) {
    final base = switch (variant) {
      SquatVariant.bodyweight => leanWarnDegBodyweight,
      SquatVariant.highBarBackSquat => leanWarnDegHBBS,
    };
    return base + (longFemur ? longFemurLeanBoost : 0.0);
  }
}
