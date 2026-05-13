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
/// Sensitivity (`FeedbackSensitivity.high`/`medium`) does NOT affect push-up
/// ROM gates — calibration personalizes them per-user; sensitivity affects
/// the form analyzer's quality-scoring thresholds (not yet split into a
/// `push_up_form_thresholds.dart` file).
library;

import 'constants.dart';

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

/// Cold-start ROM defaults for push-up.
///
/// `defaults` is the singleton tuple used before a user completes personal
/// calibration. Lookup mirrors `CurlRomDefaults` / `SquatRomDefaults` so the
/// per-exercise files stay shape-consistent.
class PushUpRomDefaults {
  const PushUpRomDefaults._();

  /// The shipping default — hand-tuned, used only as the pre-calibration
  /// fallback (see file-level provenance doc-block above).
  static const PushUpRomThresholdSet defaults = PushUpRomThresholdSet(
    startAngle: kPushUpStartAngle,
    bottomAngle: kPushUpBottomAngle,
    endAngle: kPushUpEndAngle,
    shallowRepMaxAngle: kPushUpShallowRepMaxAngle,
  );
}
