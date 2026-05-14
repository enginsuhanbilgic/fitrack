/// Fixed biomechanical thresholds for squat form audit.
///
/// **NOT tier-dependent.** Per the Sensitivity vs Form Audit doctrine
/// (`.agent_brain/SKILLS.md`, 2026-05-14), form audit encodes biomechanical
/// truth, not user preference: a 50° forward lean is concerning regardless of
/// which `FeedbackSensitivity` tier the user selected.
///
/// These constants are the single source of truth for the squat form-audit
/// values returned by [SquatFormThresholds.defaults]. Pre-2026-05-14 the same
/// values lived only in `constants.dart` and were exposed via
/// `SquatFormThresholds.forSensitivity(tier)` — that factory is removed; this
/// file replaces the lookup with a single fixed answer.
///
/// Values match the previous `medium`-tier values verbatim so existing medium
/// users see no behavior change. High users get marginally more lenient form
/// warnings (the corrected behavior — pre-2026-05-14 high was the safety
/// inversion documented in `.agent_brain/WISDOM.md`).
library;

import 'constants.dart';

class SquatFormAuditDefaults {
  const SquatFormAuditDefaults._();

  /// Bodyweight squat: forward-lean warning threshold (degrees).
  static const double leanWarnDegBodyweight = kSquatLeanWarnDegBodyweight;

  /// High-bar back squat: forward-lean warning threshold (degrees).
  static const double leanWarnDegHBBS = kSquatLeanWarnDegHBBS;

  /// Long-femur additive boost on the lean gate (degrees). Applied at the
  /// call site (`SquatFormAnalyzer`) when the "Tall lifter" Settings toggle
  /// is on, so this class stays free of that user-preference state.
  static const double longFemurLeanBoost = kSquatLongFemurLeanBoost;

  /// Knee-shift warning threshold (ratio).
  static const double kneeShiftWarnRatio = kSquatKneeShiftWarnRatio;

  /// Heel-lift warning threshold (ratio).
  static const double heelLiftWarnRatio = kSquatHeelLiftWarnRatio;
}
