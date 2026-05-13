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

import 'constants.dart';
import 'types.dart';

/// Injectable form-error thresholds for [SquatFormAnalyzer].
///
/// Mirrors [FormThresholds] for biceps curl. Decouples [SquatFormAnalyzer]
/// from global k* constants so tests and future sensitivity variants can
/// inject different values without recompiling. The numeric values live in
/// `constants.dart` (the project's single source of truth); this class adds
/// the per-variant switch + literature provenance.
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

  /// Matches the current hard-coded constants exactly.
  /// Default for all callers until a squat sensitivity dial is introduced.
  static const SquatFormThresholds defaults = SquatFormThresholds(
    leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight,
    leanWarnDegHBBS: kSquatLeanWarnDegHBBS,
    longFemurLeanBoost: kSquatLongFemurLeanBoost,
    kneeShiftWarnRatio: kSquatKneeShiftWarnRatio,
    heelLiftWarnRatio: kSquatHeelLiftWarnRatio,
  );

  /// Builds thresholds for a given [FeedbackSensitivity] level.
  ///
  /// Additive deltas per metric (not a uniform multiplier) because lean (°),
  /// knee-shift (ratio ~0.30), and heel-lift (ratio ~0.03) live on incompatible
  /// scales. Deltas mirror the Python script's SQUAT_SENSITIVITIES block:
  ///   high   — lean −3°, shift −0.03, lift −0.005  (tighter gates)
  ///   medium — no delta                              (== defaults)
  ///   low    — lean +8°, shift +0.08, lift +0.012   (more permissive)
  factory SquatFormThresholds.forSensitivity(FeedbackSensitivity s) {
    final (leanDelta, shiftDelta, liftDelta) = switch (s) {
      FeedbackSensitivity.high => (-3.0, -0.03, -0.005),
      FeedbackSensitivity.medium => (0.0, 0.0, 0.0),
    };
    return SquatFormThresholds(
      leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight + leanDelta,
      leanWarnDegHBBS: kSquatLeanWarnDegHBBS + leanDelta,
      longFemurLeanBoost: kSquatLongFemurLeanBoost,
      kneeShiftWarnRatio: kSquatKneeShiftWarnRatio + shiftDelta,
      heelLiftWarnRatio: kSquatHeelLiftWarnRatio + liftDelta,
    );
  }

  /// Effective lean threshold for a given variant + long-femur flag.
  double leanWarnFor(SquatVariant variant, {bool longFemur = false}) {
    final base = switch (variant) {
      SquatVariant.bodyweight => leanWarnDegBodyweight,
      SquatVariant.highBarBackSquat => leanWarnDegHBBS,
    };
    return base + (longFemur ? longFemurLeanBoost : 0.0);
  }
}
