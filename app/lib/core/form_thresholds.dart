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
///
/// ## Form Tolerance Percent (2026-05-15)
/// The audit thresholds themselves remain fixed by doctrine, but the
/// **dead-band layer** (the `kFormMinMovement*` family that gates each
/// audit comparison from firing on sub-noise jitter) is now user-tunable
/// via [formTolerancePercent] in `[0, 100]`. The effective dead-band for
/// each cue is computed by linear interpolation between the baseline
/// (today's hard-coded dead-band, equivalent to `percent = 0`) and the
/// audit threshold itself (equivalent to `percent = 100`):
///
///     effective = baseline + (threshold - baseline) * percent / 100
///
/// At `percent = 0` the analyzer behaves bit-for-bit like the 2026-05-15
/// retune — every existing user upgrades with no behavior change. At
/// `percent = 100` the dead-band collapses onto the audit threshold, so
/// the analyzer only fires when magnitude > threshold (the dead-band gate
/// becomes a no-op). The audit threshold is the ceiling; the slider
/// widens silence below it, never weakens it.
///
/// Doctrine compliance: scaling the **dead-band** is permitted because
/// the dead-band is a noise-floor guard, not a safety threshold. Scaling
/// the **audit threshold** would re-introduce the 2026-05-14 safety
/// inversion bug and is therefore forbidden.
library;

import 'constants.dart';
import 'curl_form_audit_defaults.dart';

class FormThresholds {
  const FormThresholds({
    required this.swingThreshold,
    required this.torsoLeanThresholdDeg,
    required this.backLeanThresholdDeg,
    required this.shrugThreshold,
    required this.driftThreshold,
    required this.elbowRiseThreshold,
    this.formTolerancePercent = kDefaultFormTolerancePercent,
  });

  final double swingThreshold;
  final double torsoLeanThresholdDeg;
  final double backLeanThresholdDeg;
  final double shrugThreshold;
  final double driftThreshold;
  final double elbowRiseThreshold;

  /// User-controlled "form tolerance" in `[0, 100]`. Scales the effective
  /// dead-band between the baseline (`kFormMinMovement*`, equivalent to
  /// `0`) and the corresponding audit threshold (equivalent to `100`).
  /// Values outside `[0, 100]` are clamped at read-time inside each
  /// effective-deadband getter; consumers should normally pass clamped
  /// values via [withTolerance].
  ///
  /// Does NOT affect rep counting, quality scoring, or post-session
  /// audit summaries — only the live cue-firing stream consumed by TTS
  /// and on-screen highlights.
  final int formTolerancePercent;

  /// Canonical fixed instance. Sourced from [CurlFormAuditDefaults] so the
  /// values have one home (the defaults file) and one consumer surface (this
  /// class).
  ///
  /// **The `medium` name is misleading legacy** — it references a tier the
  /// 2026-05-14 doctrine (`.agent_brain/SKILLS.md` → "Sensitivity vs Form
  /// Audit") explicitly abolished for form audit. The name is preserved for
  /// source-compat with default-arg call sites (`RepCounter`, `CurlStrategy`,
  /// `CurlSideFormAnalyzer`) — renaming touches 6+ signatures with no
  /// behavioral payoff. Semantically this is "the fixed thresholds with
  /// default tolerance (strictest dead-band)"; there is no high tier any
  /// more for form audit. New callers may treat this as
  /// `FormThresholds.defaults` in their head.
  static const FormThresholds medium = FormThresholds(
    swingThreshold: CurlFormAuditDefaults.swingThreshold,
    torsoLeanThresholdDeg: CurlFormAuditDefaults.torsoLeanThresholdDeg,
    backLeanThresholdDeg: CurlFormAuditDefaults.backLeanThresholdDeg,
    shrugThreshold: CurlFormAuditDefaults.shrugThreshold,
    driftThreshold: CurlFormAuditDefaults.driftThreshold,
    elbowRiseThreshold: CurlFormAuditDefaults.elbowRiseThreshold,
  );

  /// Copies [medium] with a user-supplied [percent]. Inputs outside
  /// `[0, 100]` are clamped before being stored on the new instance so
  /// downstream getters never see an invalid value.
  ///
  /// Implemented as a [_copyWith] of [medium] rather than restating each
  /// audit-threshold field — if `CurlFormAuditDefaults` grows a new field
  /// later, only `medium` needs to know about it.
  factory FormThresholds.withTolerance(int percent) =>
      medium._copyWith(formTolerancePercent: percent.clamp(0, 100));

  FormThresholds _copyWith({int? formTolerancePercent}) => FormThresholds(
    swingThreshold: swingThreshold,
    torsoLeanThresholdDeg: torsoLeanThresholdDeg,
    backLeanThresholdDeg: backLeanThresholdDeg,
    shrugThreshold: shrugThreshold,
    driftThreshold: driftThreshold,
    elbowRiseThreshold: elbowRiseThreshold,
    formTolerancePercent: formTolerancePercent ?? this.formTolerancePercent,
  );

  // ── Effective dead-bands (2026-05-15) ─────────────────────────────────
  // Linear interpolation between baseline and threshold per the file-level
  // doc-block formula. Each getter applies the §4.2 defensive clamp:
  // if `baseline >= threshold` (should never happen but guards against a
  // bad retune), the getter returns the baseline so the analyzer stays
  // operational. Constructed as getters rather than fields so the class
  // can remain `const`-constructible at `FormThresholds.medium`.

  double get effectiveSwingDeadband =>
      _effectiveDeadband(kFormMinMovementSwingRatio, swingThreshold);

  double get effectiveLeanDeadband =>
      _effectiveDeadband(kFormMinMovementLeanDeg, torsoLeanThresholdDeg);

  double get effectiveBackLeanDeadband =>
      _effectiveDeadband(kFormMinMovementLeanDeg, backLeanThresholdDeg);

  double get effectiveShrugDeadband =>
      _effectiveDeadband(kFormMinMovementShrugRatio, shrugThreshold);

  double get effectiveDriftDeadband =>
      _effectiveDeadband(kFormMinMovementDriftRatio, driftThreshold);

  double get effectiveRiseDeadband =>
      _effectiveDeadband(kFormMinMovementRiseRatio, elbowRiseThreshold);

  /// Pure interpolation helper.
  ///
  /// Returns `baseline` when `baseline >= threshold` (degenerate-but-safe
  /// — the analyzer keeps working; only the slider degenerates to a no-op
  /// for that cue). Clamps [formTolerancePercent] to `[0, 100]` at read
  /// time as a second line of defense against caller bugs that bypass
  /// [withTolerance].
  double _effectiveDeadband(double baseline, double threshold) {
    if (baseline >= threshold) return baseline;
    final percent = formTolerancePercent.clamp(0, 100);
    return baseline + (threshold - baseline) * percent / 100.0;
  }
}
