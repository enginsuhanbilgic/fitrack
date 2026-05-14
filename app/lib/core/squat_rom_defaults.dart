/// ROM threshold defaults for the **squat FSM**.
///
/// One of three per-exercise `*_rom_defaults.dart` files. File naming follows
/// the exercise; provenance is documented in the doc-block below per the
/// 2026-05-13 project convention.
///
/// PROVENANCE — hand-tuned, literature-anchored
/// ────────────────────────────────────────────
/// Unlike `curl_rom_defaults.dart` (telemetry-derived from in-app diagnostic
/// sessions), the squat FSM gates below are **hand-tuned numerical defaults**
/// anchored to the master research spec (`docs/squat/SQUAT_MASTER_SPEC.md`).
/// FiTrack does not yet run a diagnostic-session telemetry pipeline for squat;
/// when it does, this file will host the derived constants and the provenance
/// section above will be updated to "telemetry-derived" with a session-date
/// reference.
///
/// The underlying numeric constants (`kSquatStartAngle`, `kSquatBottomAngle`,
/// `kSquatEndAngle`, and their `*High` counterparts) live in `constants.dart`
/// as the single source of truth — `SquatStrategy` and tests reference them
/// directly. This file re-exposes them through a [SquatRomDefaults] view-object
/// so consumers reaching for "where do squat ROM thresholds come from?" land
/// on a file named after the exercise, with provenance up top.
///
/// FSM SHAPE
/// ─────────
/// The squat FSM is three states (IDLE → DESCENDING → ASCENDING → IDLE),
/// gated by three angles applied to the knee:
///   * startAngle  — IDLE → DESCENDING trigger (deeper = stricter start gate)
///   * bottomAngle — DESCENDING → ASCENDING trigger (deeper = stricter depth)
///   * endAngle    — ASCENDING → IDLE trigger → rep++ (deeper = stricter return)
///
/// Note: there is no `peakExit` gate (unlike curl) because the squat FSM uses
/// the same threshold to enter and leave the bottom phase — the rep is
/// committed at the minimum-angle frame within the ASCENDING phase, not on a
/// hysteresis crossing.
///
/// SENSITIVITY CONTRACT (2026-05-14)
/// ─────────────────────────────────
/// Every factory returns the **High-anchored** tuple. `applySensitivity(s)`
/// is the post-pass that turns the High anchor into the user's selected level.
/// Apply it at the call site (resolver in `WorkoutViewModel`) — not inside
/// the factories — so the contract mirrors curl. Looseness deltas reproduce
/// today's Medium-baseline numbers bit-for-bit when applied to the High
/// anchor: `(dStart=-5, dBottom=+2, dEnd=-3)`.
///
/// VARIANT-DEPENDENT BOTTOM ANGLE
/// ──────────────────────────────
/// `SquatStrategy` adapts `bottomAngle` per session via two mechanisms not
/// captured in the defaults below:
///   1. **Long-femur auto-detection** — the strategy widens the bottom gate
///      to `kLongFemurBottomAngle` for users whose first 5 reps all stay
///      shallower than 90°. See `SquatStrategy.effectiveBottomAngle`.
///   2. **Personal calibration** — calibration produces a per-user threshold
///      tuple via [SquatRomThresholdSet.fromBucket].
library;

import 'constants.dart';
import 'types.dart';

/// Immutable view-specific squat threshold tuple.
///
/// Parallels [CurlRomThresholdSet] in shape so consumers reaching for either
/// exercise see the same three-tuple convention. The fields below mirror the
/// three gates of the squat FSM.
class SquatRomThresholdSet {
  const SquatRomThresholdSet({
    required this.startAngle,
    required this.bottomAngle,
    required this.endAngle,
  });

  /// IDLE → DESCENDING when knee angle drops below this.
  final double startAngle;

  /// DESCENDING → ASCENDING when knee angle drops below this.
  final double bottomAngle;

  /// ASCENDING → IDLE when knee angle returns above this → rep++.
  final double endAngle;

  /// Looseness deltas: `(dStart, dBottom, dEnd)` applied to the High anchor
  /// to reproduce today's Medium-baseline numbers exactly.
  /// `dBottom=+2` means Medium accepts a *shallower* bottom (less strict).
  static const (double, double, double) _mediumLooseness = (-5.0, 2.0, -3.0);

  /// Returns the High anchor — bit-for-bit identical to today's
  /// `forSensitivity(high)` output.
  ///
  /// Apply [applySensitivity] at the call site to derive Medium.
  static const SquatRomThresholdSet anchor = SquatRomThresholdSet(
    startAngle: kSquatStartAngleHigh,
    bottomAngle: kSquatBottomAngleHigh,
    endAngle: kSquatEndAngleHigh,
  );

  /// Apply the user's sensitivity selection to a High-anchored threshold set.
  ///
  /// Returns `this` unmodified for High. For Medium, applies looseness deltas
  /// and re-asserts the squat FSM's per-gate floors against `bottom`.
  ///
  /// Idempotent on High; safe to call from any tier's resolver as the last
  /// op before returning to the FSM driver.
  ///
  /// FSM contract (per `squat_strategy.dart`):
  ///   * `start > bottom` so IDLE → DESCENDING can fire.
  ///   * `end > bottom` so ASCENDING → IDLE can fire.
  /// `start` and `end` are independent — bucket-derived anchors routinely
  /// produce `end > start` (e.g. profile margins 10° vs 5°) and the FSM
  /// handles it correctly because the two gates apply to different
  /// transitions.
  SquatRomThresholdSet applySensitivity(FeedbackSensitivity sensitivity) {
    if (sensitivity == FeedbackSensitivity.high) return this;
    final (dStart, dBottom, dEnd) = _mediumLooseness;
    final start = startAngle + dStart;
    final bottom = bottomAngle + dBottom;
    final end = endAngle + dEnd;
    final safeStart = start > bottom + 1.0 ? start : bottom + 1.0;
    final safeEnd = end > bottom + 1.0 ? end : bottom + 1.0;
    return SquatRomThresholdSet(
      startAngle: safeStart,
      bottomAngle: bottom,
      endAngle: safeEnd,
    );
  }

  /// Backwards-compatible factory. Returns the High anchor unconditionally;
  /// the caller is responsible for applying [applySensitivity] at the
  /// resolver. Kept so call sites that already invoke `forSensitivity` keep
  /// compiling while migration is in flight.
  ///
  /// Prefer reading [anchor] directly + chaining [applySensitivity] in new
  /// code — it makes the High-anchor contract self-documenting.
  factory SquatRomThresholdSet.forSensitivity(FeedbackSensitivity s) {
    return anchor.applySensitivity(s);
  }

  /// Derive a threshold tuple from a calibrated profile bucket. Returns the
  /// **High-anchored** tuple — apply [applySensitivity] at the call site.
  ///
  /// `[observedMinKneeAngle, observedMaxKneeAngle]` define the user's
  /// personal ROM extremes; this factory applies the standard margins
  /// ([kSquatProfileStartMargin] / [kSquatProfileBottomMargin] /
  /// [kSquatProfileEndMargin]) to produce the FSM gates. Mirrors curl's
  /// `RomThresholds.fromBucket` so a future change to the margin policy
  /// has exactly one place to land.
  factory SquatRomThresholdSet.fromBucket({
    required double observedMinKneeAngle,
    required double observedMaxKneeAngle,
  }) {
    return SquatRomThresholdSet(
      startAngle: observedMaxKneeAngle - kSquatProfileStartMargin,
      bottomAngle: observedMinKneeAngle + kSquatProfileBottomMargin,
      endAngle: observedMaxKneeAngle - kSquatProfileEndMargin,
    );
  }
}

/// Per-variant squat ROM defaults (currently variant-agnostic — values
/// derived from the hand-tuned constants in `constants.dart`).
///
/// Lookup mirrors `CurlRomDefaults.forView` so the per-exercise files stay
/// shape-consistent. When telemetry-derived squat thresholds land, this
/// class is where the per-variant branching will appear.
class SquatRomDefaults {
  const SquatRomDefaults._();

  /// The shipping High anchor — variant-agnostic, hand-tuned. Today's
  /// `forSensitivity(high)` numbers, preserved bit-for-bit.
  ///
  /// Pre-2026-05-14 this field held today's Medium-baseline numbers under the
  /// name `defaults`. The rename reflects the new contract: every factory
  /// returns High; Medium is derived at the call site.
  static const SquatRomThresholdSet anchor = SquatRomThresholdSet.anchor;

  /// Backwards-compatible alias. Points at the **High anchor** under the new
  /// sensitivity contract — call sites that read this directly now get the
  /// strict numbers. Migrate to [anchor] + `.applySensitivity(s)` at the
  /// resolver level when touching nearby code.
  static const SquatRomThresholdSet defaults = anchor;

  /// Look up the squat threshold tuple for a given variant.
  ///
  /// Returns the **High anchor**. Today both variants share the same anchor —
  /// the per-variant differences surface only in form thresholds (lean angle,
  /// long-femur adaptation) and in `SquatStrategy.effectiveBottomAngle`. When
  /// telemetry-derived squat thresholds arrive, this method gains a
  /// `switch (variant)` body.
  static SquatRomThresholdSet forVariant(SquatVariant variant) => anchor;

  /// Combined variant + sensitivity lookup. Today the result is variant-
  /// agnostic — the sensitivity dial is the only axis that affects the FSM
  /// gates here — so this delegates to [anchor] + [applySensitivity].
  /// The signature is kept symmetric with [forVariant] so a future
  /// per-variant ROM split (e.g. wider BOTTOM for HBBS) lands as a single
  /// method body change with no call-site churn.
  static SquatRomThresholdSet forVariantAndSensitivity(
    SquatVariant variant,
    FeedbackSensitivity sensitivity,
  ) => forVariant(variant).applySensitivity(sensitivity);
}
