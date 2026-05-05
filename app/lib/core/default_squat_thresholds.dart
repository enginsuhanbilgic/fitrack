/// ═══════════════════════════════════════════════════════════════════
/// Default squat form-error thresholds — literature-anchored.
/// ═══════════════════════════════════════════════════════════════════
///
/// Unlike `default_rom_thresholds.dart` (curl, dataset-derived via
/// Phase D-v2), these values are NOT derived from a recorded dataset.
/// FiTrack does not run a Phase D-v2 statistical pipeline for squat;
/// the values below come from the master research spec
/// (`docs/squat/SQUAT_MASTER_SPEC.md`) which synthesizes two
/// independent deep-research reports.
///
/// STATUS LEGEND
/// ─────────────
///   ✅ literature-anchored, safe to ship as v1
///   ⚠️ literature-anchored with measurement-noise margin
///   (empirical-TBD) engineering estimate; promote with care
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

import 'constants.dart';
import 'types.dart';

/// Per-variant lookup for the active lean warning threshold. The
/// `+kSquatLongFemurLeanBoost` add-on is applied at the call site
/// (`SquatFormAnalyzer`) when the "Tall lifter" Settings toggle is on,
/// so this class stays free of that user-preference state.
///
/// The numeric values live in `constants.dart` (the project's single
/// source of truth for thresholds); this class adds the per-variant
/// switch + literature provenance comments. CIs and citations are
/// retained here so the doc-string stays close to the lookup.
class DefaultSquatThresholds {
  const DefaultSquatThresholds._();

  // ⚠️ Lean — Glassbrook 2017 + Straub & Powers 2024, +5° margin
  /// CI [40, 50]
  static const double leanWarnDegBodyweight = kSquatLeanWarnDegBodyweight;

  /// CI [45, 55]
  static const double leanWarnDegHBBS = kSquatLeanWarnDegHBBS;
  static const double longFemurLeanBoost = kSquatLongFemurLeanBoost;

  // (empirical-TBD) Forward knee shift — Hartmann 2013
  /// Research docs disagreed 3× (Claude 0.30, Google 0.10). CI [0.10, 0.35].
  static const double kneeShiftWarnRatio = kSquatKneeShiftWarnRatio;

  // (empirical-TBD) Heel lift — Macrum 2012, engineering estimate
  /// CI [0.02, 0.04]
  static const double heelLiftWarnRatio = kSquatHeelLiftWarnRatio;

  // ✅ Quality scoring weights (mirror curl multiplicative deduction)
  static const double weightLean = kQualitySquatLeanMaxDeduction;
  static const double weightHeelLift = kQualitySquatHeelLiftMaxDeduction;

  /// Per-variant lookup. Used by `SquatStrategy` at construction.
  static double leanWarnFor(SquatVariant v) => switch (v) {
    SquatVariant.bodyweight => leanWarnDegBodyweight,
    SquatVariant.highBarBackSquat => leanWarnDegHBBS,
  };
}
