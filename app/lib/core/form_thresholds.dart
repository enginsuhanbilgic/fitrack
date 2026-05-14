/// Injectable bundle of form-error thresholds for biceps curl.
///
/// Replaces direct reads of the 6 `k*` constants in both analyzers so a
/// single decision made in `WorkoutViewModel.init()` flows down through
/// CurlStrategy → RepCounter without any intermediate layer needing to know
/// about the underlying constants. Pure value class — no Flutter dependency.
///
/// **NOT tier-dependent** (Sensitivity vs Form Audit doctrine, 2026-05-14).
/// Pre-2026-05-14 a `FormThresholds.forSensitivity(FeedbackSensitivity)`
/// factory tightened gates on `high` (multiplier 0.75) — that produced a
/// safety inversion where users on the *gentler* tier got *weaker* form
/// warnings. The factory is removed; callers use [FormThresholds.medium]
/// (the canonical fixed instance, sourced from [CurlFormAuditDefaults]).
library;

import 'curl_form_audit_defaults.dart';

class FormThresholds {
  const FormThresholds({
    required this.swingThreshold,
    required this.torsoLeanThresholdDeg,
    required this.backLeanThresholdDeg,
    required this.shrugThreshold,
    required this.driftThreshold,
    required this.elbowRiseThreshold,
  });

  final double swingThreshold;
  final double torsoLeanThresholdDeg;
  final double backLeanThresholdDeg;
  final double shrugThreshold;
  final double driftThreshold;
  final double elbowRiseThreshold;

  /// Canonical fixed instance. Sourced from [CurlFormAuditDefaults] so the
  /// values have one home (the defaults file) and one consumer surface (this
  /// class).
  ///
  /// **The `medium` name is misleading legacy** — it references a tier the
  /// 2026-05-14 doctrine (`.agent_brain/SKILLS.md` → "Sensitivity vs Form
  /// Audit") explicitly abolished for form audit. The name is preserved for
  /// source-compat with default-arg call sites (`RepCounter`, `CurlStrategy`,
  /// `CurlSideFormAnalyzer`) — renaming touches 6+ signatures with no
  /// behavioral payoff. Semantically this is "the fixed thresholds," not
  /// "the medium tier"; there is no high tier any more for form audit. New
  /// callers may treat this as `FormThresholds.defaults` in their head.
  static const FormThresholds medium = FormThresholds(
    swingThreshold: CurlFormAuditDefaults.swingThreshold,
    torsoLeanThresholdDeg: CurlFormAuditDefaults.torsoLeanThresholdDeg,
    backLeanThresholdDeg: CurlFormAuditDefaults.backLeanThresholdDeg,
    shrugThreshold: CurlFormAuditDefaults.shrugThreshold,
    driftThreshold: CurlFormAuditDefaults.driftThreshold,
    elbowRiseThreshold: CurlFormAuditDefaults.elbowRiseThreshold,
  );
}
