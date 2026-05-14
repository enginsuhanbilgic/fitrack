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
/// the Medium-baseline single source of truth — `PushUpStrategy`,
/// `PushUpFormAnalyzer`, and `PushUpRomProfile` reference them directly for
/// non-sensitivity-aware paths (cold-start bucket seeding, FSM defaults).
/// This file re-exposes them through a [PushUpRomDefaults] view-object so
/// consumers reaching for "where do push-up ROM thresholds come from?" land
/// on a file named after the exercise, with provenance up top.
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
/// SENSITIVITY CONTRACT (2026-05-14)
/// ─────────────────────────────────
/// [forSensitivity] / [anchor] return the **High-anchored** tuple
/// unconditionally. Sensitivity is applied as a post-pass via
/// [PushUpRomThresholdSet.applySensitivity] — mirrors curl's
/// `RomThresholds.applySensitivity` and squat's
/// `SquatRomThresholdSet.applySensitivity`. Looseness deltas reproduce
/// today's `_medium` numbers bit-for-bit:
///   `(dStart=-5, dBottom=+5, dEnd=-3, dShallow=+5)`
///
/// CALIBRATION-RELATED CONSTANTS
/// ─────────────────────────────
/// The calibration acceptance bounds (`kPushUpCalibration*`), profile-margin
/// constants (`kPushUpProfile*`), hold duration, and max-spread tolerance
/// remain in `constants.dart` — they are infrastructure parameters for the
/// calibration flow, not ROM gate values. This file scopes itself to the
/// FSM gate quadruple only.
library;

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

  /// Looseness deltas: `(dStart, dBottom, dEnd, dShallow)` applied to the
  /// High anchor to reproduce today's Medium-baseline (legacy `_medium`)
  /// numbers exactly. `dBottom=+5` means Medium accepts a shallower bottom.
  static const (double, double, double, double) _mediumLooseness = (
    -5.0,
    5.0,
    -3.0,
    5.0,
  );

  /// Apply the user's sensitivity selection to a High-anchored threshold set.
  ///
  /// Returns `this` unmodified for High. For Medium, applies looseness
  /// deltas. Idempotent on High; safe to call from any tier's resolver as
  /// the last op before returning to the FSM driver.
  PushUpRomThresholdSet applySensitivity(FeedbackSensitivity sensitivity) {
    if (sensitivity == FeedbackSensitivity.high) return this;
    final (dStart, dBottom, dEnd, dShallow) = _mediumLooseness;
    return PushUpRomThresholdSet(
      startAngle: startAngle + dStart,
      bottomAngle: bottomAngle + dBottom,
      endAngle: endAngle + dEnd,
      shallowRepMaxAngle: shallowRepMaxAngle + dShallow,
    );
  }
}

/// Cold-start ROM defaults for push-up — High-anchored.
///
/// Pre-2026-05-14: this class returned a Medium-baseline tuple by default and
/// a High tuple via [forSensitivity]. After 2026-05-14: returns the
/// High-anchored tuple unconditionally; the caller applies sensitivity via
/// [PushUpRomThresholdSet.applySensitivity] at the resolver level.
class PushUpRomDefaults {
  const PushUpRomDefaults._();

  /// The shipping cold-start **High anchor**. Numbers preserved bit-for-bit
  /// from pre-2026-05-14 `_high` — stricter start, deeper bottom required,
  /// stricter return-to-extension.
  static const PushUpRomThresholdSet anchor = PushUpRomThresholdSet(
    startAngle: 165,
    bottomAngle: 85,
    endAngle: 163,
    shallowRepMaxAngle: 125,
  );

  /// Backwards-compatible factory. Returns the High anchor unconditionally;
  /// the caller is responsible for applying [PushUpRomThresholdSet.applySensitivity]
  /// at the resolver. Kept so call sites that already invoke `forSensitivity`
  /// keep compiling while migration is in flight.
  ///
  /// Prefer reading [anchor] directly + chaining `.applySensitivity(s)` in
  /// new code.
  static PushUpRomThresholdSet forSensitivity(FeedbackSensitivity s) {
    return anchor.applySensitivity(s);
  }

  /// Backwards-compatible alias. Points at the **High anchor** under the new
  /// sensitivity contract. Pre-2026-05-14 callers that read this directly
  /// got the Medium-baseline tuple; they now get the stricter High numbers.
  /// Migrate to [anchor] + `.applySensitivity(s)` at the resolver level
  /// when touching nearby code.
  static const PushUpRomThresholdSet defaults = anchor;
}
