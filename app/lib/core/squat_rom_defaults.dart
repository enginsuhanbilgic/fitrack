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
/// `kSquatEndAngle`) live in `constants.dart` as a single source of truth —
/// `SquatStrategy` and tests reference them directly. This file re-exposes
/// them through a [SquatRomDefaults] view-object so consumers reaching for
/// "where do squat ROM thresholds come from?" land on a file named after the
/// exercise, with provenance up top.
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
/// VARIANT-DEPENDENT BOTTOM ANGLE
/// ──────────────────────────────
/// `SquatStrategy` adapts `bottomAngle` per session via two mechanisms not
/// captured in the defaults below:
///   1. **Long-femur auto-detection** — the strategy widens the bottom gate
///      to `kLongFemurBottomAngle` for users whose first 5 reps all stay
///      shallower than 90°. See `SquatStrategy.effectiveBottomAngle`.
///   2. **Personal calibration** — not currently implemented for squat;
///      mirrors push-up's pattern when it is.
///
/// Sensitivity (`FeedbackSensitivity.high`/`medium`) affects squat **form
/// thresholds** (`squat_form_thresholds.dart`), NOT the ROM gates here.
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

  /// Build the threshold tuple for the requested [FeedbackSensitivity].
  ///
  /// `medium` returns [SquatRomDefaults.defaults] — bit-for-bit identical to
  /// the legacy hand-tuned constants ([kSquatStartAngle] / [kSquatBottomAngle]
  /// / [kSquatEndAngle]). `high` returns the tighter research-derived gates
  /// ([kSquatStartAngleHigh] / [kSquatBottomAngleHigh] / [kSquatEndAngleHigh]).
  ///
  /// Exhaustive switch — adding a future enum case is a compile error here.
  factory SquatRomThresholdSet.forSensitivity(FeedbackSensitivity s) {
    return switch (s) {
      FeedbackSensitivity.high => const SquatRomThresholdSet(
        startAngle: kSquatStartAngleHigh,
        bottomAngle: kSquatBottomAngleHigh,
        endAngle: kSquatEndAngleHigh,
      ),
      FeedbackSensitivity.medium => SquatRomDefaults.defaults,
    };
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

  /// The shipping default — variant-agnostic, hand-tuned (see file-level
  /// provenance doc-block above).
  static const SquatRomThresholdSet defaults = SquatRomThresholdSet(
    startAngle: kSquatStartAngle,
    bottomAngle: kSquatBottomAngle,
    endAngle: kSquatEndAngle,
  );

  /// Look up the squat threshold tuple for a given variant.
  ///
  /// Today both variants share the same defaults — the per-variant differences
  /// surface only in form thresholds (lean angle, long-femur adaptation) and
  /// in `SquatStrategy.effectiveBottomAngle`. When telemetry-derived squat
  /// thresholds arrive, this method gains a `switch (variant)` body.
  static SquatRomThresholdSet forVariant(SquatVariant variant) => defaults;

  /// Combined variant + sensitivity lookup. Today the result is variant-
  /// agnostic — the sensitivity dial is the only axis that affects the FSM
  /// gates here — so this delegates to [SquatRomThresholdSet.forSensitivity].
  /// The signature is kept symmetric with [forVariant] so a future
  /// per-variant ROM split (e.g. wider BOTTOM for HBBS) lands as a single
  /// method body change with no call-site churn.
  static SquatRomThresholdSet forVariantAndSensitivity(
    SquatVariant variant,
    FeedbackSensitivity sensitivity,
  ) => SquatRomThresholdSet.forSensitivity(sensitivity);
}
