/// Fixed biomechanical thresholds for biceps-curl form audit.
///
/// **NOT tier-dependent.** Per the Sensitivity vs Form Audit doctrine
/// (`.agent_brain/SKILLS.md`, 2026-05-14), form audit encodes biomechanical
/// truth, not user preference. The pre-2026-05-14 `FormThresholds.forSensitivity`
/// factory tightened these gates on `high` (multiplier 0.75) — that produced a
/// safety inversion where users who picked the *gentler* tier got *weaker*
/// form warnings. The factory is removed; this file replaces the lookup with
/// a single fixed answer.
///
/// Values match the previous `medium`-tier values verbatim (i.e. the
/// `kSwingThreshold` family of constants with a multiplier of 1.0) so existing
/// medium users see no behavior change. High users get marginally more lenient
/// form warnings (the corrected behavior).
///
/// Used by `FormThresholds.medium` (the single fixed builder) and the form
/// audit consumers in `engine/form_auditor.dart` and `engine/curl/`.
library;

import 'constants.dart';

class CurlFormAuditDefaults {
  const CurlFormAuditDefaults._();

  /// Hip/torso lateral-swing warning ratio.
  static const double swingThreshold = kSwingThreshold;

  /// Torso-lean warning (degrees).
  static const double torsoLeanThresholdDeg = kTorsoLeanThresholdDeg;

  /// Back-lean warning (degrees).
  static const double backLeanThresholdDeg = kBackLeanThresholdDeg;

  /// Shoulder-shrug warning ratio.
  static const double shrugThreshold = kShrugThreshold;

  /// Elbow/shoulder drift warning ratio.
  static const double driftThreshold = kDriftThreshold;

  /// Elbow-rise warning ratio.
  static const double elbowRiseThreshold = kElbowRiseThreshold;
}
