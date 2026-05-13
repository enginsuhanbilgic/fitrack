/// ROM threshold defaults for the **push-up FSM**.
///
/// One of three per-exercise `*_rom_defaults.dart` files. File naming follows
/// the exercise; provenance is documented in the doc-block below per the
/// 2026-05-13 project convention.
///
/// PROVENANCE — hand-tuned, calibration-driven
/// ───────────────────────────────────────────
/// Unlike `curl_rom_defaults.dart` (telemetry-derived from in-app diagnostic
/// sessions), the push-up FSM gates below are **hand-tuned numerical defaults**
/// — chosen during the 2026-04-28 → 2026-05-12 push-up engine overhaul
/// (PRs #27, #29, #31, #32, #33). The push-up architecture relies primarily on
/// **personal calibration** (`PushUpRomProfile` recorded once per user) rather
/// than on a shipping cold-start telemetry-derived bucket — the defaults
/// below are the pre-calibration fallback only.
///
/// When a future diagnostic-session telemetry pipeline is built for push-up,
/// this file will host the derived constants and the provenance section above
/// will be updated to "telemetry-derived" with a session-date reference.
///
/// The underlying numeric constants (`kPushUpStartAngle`, `kPushUpBottomAngle`,
/// `kPushUpEndAngle`, `kPushUpShallowRepMaxAngle`) live in `constants.dart` as
/// the single source of truth — `PushUpStrategy`, `PushUpFormAnalyzer`, and
/// `PushUpRomProfile` reference them directly. This file re-exposes them
/// through a [PushUpRomDefaults] view-object so consumers reaching for
/// "where do push-up ROM thresholds come from?" land on a file named after
/// the exercise, with provenance up top.
///
/// FSM SHAPE
/// ─────────
/// The push-up FSM is three states (IDLE → DESCENDING → ASCENDING → IDLE),
/// gated by three angles applied to the elbow:
///   * startAngle      — IDLE → DESCENDING trigger (deeper = stricter start)
///   * bottomAngle     — DESCENDING → ASCENDING trigger (deeper = stricter depth)
///   * endAngle        — ASCENDING → IDLE trigger → rep++ (deeper = stricter return)
///   * shallowRepMax   — angle above which a reversal-before-bottom is counted
///                       as a shallow/faulty rep instead of discarded
///
/// PERSONAL CALIBRATION OVERRIDE
/// ─────────────────────────────
/// Once a user completes push-up calibration, the FSM consumes a
/// [PushUpRomThresholds] instance derived from their personal top/bottom
/// extremes — see `engine/push_up/push_up_rom_profile.dart`. The defaults
/// below are used only as the cold-start fallback and as bounds for the
/// calibration acceptance gate.
///
/// CALIBRATION-RELATED CONSTANTS
/// ─────────────────────────────
/// The calibration acceptance bounds (`kPushUpCalibration*`), profile-margin
/// constants (`kPushUpProfile*`), hold duration, and max-spread tolerance
/// remain in `constants.dart` — they are infrastructure parameters for the
/// calibration flow, not ROM gate values. This file scopes itself to the
/// FSM gate quadruple only.
///
/// SENSITIVITY-KEYED ROM GATES (2026-05-13 design flip)
/// ────────────────────────────────────────────────────
/// Push-up ROM gates are now keyed by [FeedbackSensitivity] — see
/// [PushUpRomDefaults.forSensitivity]. This **replaces** the earlier
/// "calibration-only" stance documented in prior revisions of this file:
/// pre-calibration users still need the cold-start defaults, and a single
/// hand-tuned tuple is not a defensible cold-start for everyone. The tier
/// design rationale lives in
/// `docs/plan/2026-05-13-feat-push-up-telemetry-threshold-tuning-plan.md`.
///
/// Mapping (per-tier percentile picks, applied by the offline derivation
/// script `tools/dataset_analysis/scripts/derive_pushup_thresholds_from_telemetry.py`):
///
///   | Sensitivity | bottomAngle (P of min_elbow) | startAngle (P of max_elbow) | shallowRepMax (P of min_elbow) |
///   |-------------|------------------------------|-----------------------------|--------------------------------|
///   | **high**    | P15 (shallower → stricter)   | P85 (lower → stricter)      | P30                            |
///   | **medium**  | P10                          | P90                         | P25                            |
///
/// `endAngle` is P50 across tiers — population centers there.
///
/// **Values shipped in this PR are still hand-tuned.** The API shape lands
/// here so call sites can migrate to [forSensitivity]; a follow-up PR runs
/// the derivation script on a representative cohort and swaps the numbers.
///
/// Calibration overrides remain in force — once a user completes push-up
/// calibration, the FSM consumes their per-user [PushUpRomThresholds] from
/// `engine/push_up/push_up_rom_profile.dart`. Sensitivity affects only the
/// pre-calibration fallback.
library;

import 'constants.dart';
import 'types.dart';

/// Immutable threshold tuple for the push-up FSM.
///
/// Parallels [CurlRomThresholdSet] and [SquatRomThresholdSet] in shape so
/// consumers reaching for any exercise see the same per-exercise convention.
/// The four fields mirror the push-up FSM gates.
class PushUpRomThresholdSet {
  const PushUpRomThresholdSet({
    required this.startAngle,
    required this.bottomAngle,
    required this.endAngle,
    required this.shallowRepMaxAngle,
  });

  /// IDLE → DESCENDING when elbow angle drops below this.
  final double startAngle;

  /// DESCENDING → ASCENDING when elbow angle drops below this.
  final double bottomAngle;

  /// ASCENDING → IDLE when elbow angle returns above this → rep++.
  final double endAngle;

  /// A push-up attempt that reverses above bottom but reaches at least this
  /// elbow angle is counted as a shallow/faulty rep instead of discarded.
  final double shallowRepMaxAngle;
}

/// Cold-start ROM defaults for push-up — sensitivity-keyed.
///
/// Lookup mirrors `SquatRomDefaults.forVariantAndSensitivity` so the
/// per-exercise files stay shape-consistent. Calibration overrides per-user;
/// the tuple returned here is only used as the pre-calibration fallback.
class PushUpRomDefaults {
  const PushUpRomDefaults._();

  /// Build the cold-start tuple for the requested [FeedbackSensitivity].
  ///
  /// Values are **still hand-tuned in this PR** — the API shape lands
  /// here so consumers can migrate. The follow-up PR runs the derivation
  /// script on real telemetry and replaces these constants with derived
  /// values; the call-site contract is stable.
  ///
  /// Exhaustive switch — adding a future enum case is a compile error.
  static PushUpRomThresholdSet forSensitivity(FeedbackSensitivity s) {
    return switch (s) {
      FeedbackSensitivity.high => _high,
      FeedbackSensitivity.medium => _medium,
    };
  }

  /// Backward-compatible alias for the medium tier. Existing call sites
  /// that haven't migrated to [forSensitivity] still resolve to the same
  /// tuple they got before the sensitivity-keying restructure.
  static const PushUpRomThresholdSet defaults = _medium;

  /// High-sensitivity tier — stricter gates. Mirrors the squat high tier:
  /// stricter start (must be more extended), deeper bottom required,
  /// stricter return-to-extension. Hand-tuned with ±3-5° offsets from
  /// the medium tier; numerically derived values land in the follow-up.
  static const PushUpRomThresholdSet _high = PushUpRomThresholdSet(
    startAngle: 165,
    bottomAngle: 85,
    endAngle: 163,
    shallowRepMaxAngle: 125,
  );

  /// Medium-sensitivity tier — bit-for-bit identical to the legacy
  /// hand-tuned constants. Returning users on `medium` see no change.
  static const PushUpRomThresholdSet _medium = PushUpRomThresholdSet(
    startAngle: kPushUpStartAngle,
    bottomAngle: kPushUpBottomAngle,
    endAngle: kPushUpEndAngle,
    shallowRepMaxAngle: kPushUpShallowRepMaxAngle,
  );
}
