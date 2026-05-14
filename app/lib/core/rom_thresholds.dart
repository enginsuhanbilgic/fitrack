/// Per-rep FSM thresholds resolved from a profile bucket, the auto-calibrator,
/// or the global constants. Pure value object — no I/O, no mutation.
///
/// The FSM consumes one of these per rep and the source is locked at
/// IDLE→CONCENTRIC; it never swaps mid-rep (see plan invariant).
///
/// SENSITIVITY CONTRACT (2026-05-14)
/// ─────────────────────────────────
/// Every factory in this file returns a **High-anchored** threshold tuple.
/// `RomThresholds.applySensitivity(s)` is the single post-pass that turns the
/// High anchor into the user's selected level. Apply it at the *call site*
/// (the resolver in `WorkoutViewModel`) — not inside the factories — so the
/// diagnostic path (`globalUnmodified`) can opt out cleanly.
///
/// This brings ROM thresholds in line with how form-error thresholds already
/// work: sensitivity applies at every tier, not just cold-start.
library;

import 'constants.dart';
import 'pipeline_rom_defaults.dart';
import 'curl_rom_defaults.dart';
import 'types.dart';

/// Forward declaration shape — the real bucket lives in
/// `engine/curl/curl_rom_profile.dart`. Kept as a structural interface here
/// so this file stays in the `core/` layer with no engine dependency.
abstract class RomBucketLike {
  double get observedMinAngle; // deepest flexion (peak end)
  double get observedMaxAngle; // most extended (rest end)
}

class RomThresholds {
  /// IDLE → CONCENTRIC trigger.
  final double startAngle;

  /// CONCENTRIC → PEAK trigger.
  final double peakAngle;

  /// PEAK → ECCENTRIC trigger (peakAngle + kCurlPeakExitGap, hysteresis).
  final double peakExitAngle;

  /// ECCENTRIC → IDLE trigger → rep++.
  final double endAngle;

  /// Where these thresholds came from. For telemetry + diagnostics only.
  final ThresholdSource source;

  const RomThresholds({
    required this.startAngle,
    required this.peakAngle,
    required this.peakExitAngle,
    required this.endAngle,
    required this.source,
  });

  /// Tier-3 looseness deltas: `(dStart, dPeak, dEnd)` applied to the
  /// High-anchored constants to reproduce today's Medium numbers exactly.
  /// peakExit is re-derived from `peak + kCurlPeakExitGap`.
  static const (double, double, double) _tier3MediumLooseness = (
    -5.0,
    10.0,
    0.0,
  );

  /// Tier-1 (telemetry-derived) High anchor for curl, per view.
  /// Reproduces today's `sideLeftStrict` / `sideRightStrict` exactly.
  /// Looseness for Medium is `(-3, +8, +8)` — preserves today's `*Default`.
  /// Applied via `_applyTelemetrySensitivity` (separate path, separate
  /// floor mode) since telemetry tuples ship with curated tight gaps that
  /// the strict bucket-derived floor would over-correct.
  static const (double, double, double) _telemetryMediumLooseness = (
    -3.0,
    8.0,
    8.0,
  );

  /// Apply the user's sensitivity selection to a High-anchored threshold set.
  ///
  /// Returns `this` unmodified for High. For Medium, applies the Tier-3
  /// looseness deltas — bucket-derived (Tier-1 calibrated, Tier-2 auto-cal)
  /// and Tier-3 cold-start share the same `(-5, +10, 0)` because they both
  /// use the curl FSM's per-rep tolerance system; only the telemetry path
  /// uses a different delta tuple (handled separately via
  /// [_applyTelemetrySensitivity]).
  ///
  /// Idempotent on High; safe to call from any tier's resolver as the last
  /// op before returning to the FSM driver.
  RomThresholds applySensitivity(FeedbackSensitivity sensitivity) {
    if (sensitivity == FeedbackSensitivity.high) return this;
    final (dStart, dPeak, dEnd) = _tier3MediumLooseness;
    return _applyLooseness(this, dStart, dPeak, dEnd);
  }

  /// Variant of [applySensitivity] that uses telemetry-specific deltas.
  /// Called inside [global] when the Tier-1 telemetry path wins, since
  /// that tier's strict/loose gap differs from Tier-3's hand-tuned gap.
  ///
  /// Uses the **soft floor** (`end > peakExit` only) — telemetry tuples are
  /// hand-crafted with small end-to-peakExit gaps that are valid for the
  /// curl FSM but would fail the strict bucket-derived floor.
  RomThresholds _applyTelemetrySensitivity(FeedbackSensitivity sensitivity) {
    if (sensitivity == FeedbackSensitivity.high) return this;
    final (dStart, dPeak, dEnd) = _telemetryMediumLooseness;
    return _applyLooseness(this, dStart, dPeak, dEnd, strictFloor: false);
  }

  /// Pure delta application. Re-derives peakExit from peak + gap and
  /// asserts FSM completability invariant.
  ///
  /// `strictFloor` controls how much margin is enforced between `end` and
  /// `peakExit`:
  /// - `true` (default, for bucket-derived/Tier-3 paths): `end > peakExit + gap`.
  ///   The extra gap is required because restricted-ROM buckets (e.g. 90°/130°)
  ///   can produce raw `end ≤ peakExit`, an uncompletable FSM.
  /// - `false` (telemetry path): `end > peakExit` only. Telemetry tuples are
  ///   curated and ship with small end-to-peakExit gaps that the FSM handles
  ///   fine but that would be over-corrected by the strict floor.
  static RomThresholds _applyLooseness(
    RomThresholds base,
    double dStart,
    double dPeak,
    double dEnd, {
    bool strictFloor = true,
  }) {
    final peak = base.peakAngle + dPeak;
    final start = base.startAngle + dStart;
    final end = base.endAngle + dEnd;
    final peakExit = peak + kCurlPeakExitGap;
    final endFloor = strictFloor ? peakExit + kCurlPeakExitGap : peakExit + 0.1;
    final safeEnd = end > endFloor ? end : endFloor;
    final safeStart = start > safeEnd ? start : safeEnd + 1.0;
    return RomThresholds(
      startAngle: safeStart,
      peakAngle: peak,
      peakExitAngle: peakExit,
      endAngle: safeEnd,
      source: base.source,
    );
  }

  /// Returns the cold-start / [ThresholdSource.global] threshold set,
  /// already sensitivity-modified.
  ///
  /// Three-tier resolver (Tier 1 is canonical; Tier 2 shelved):
  ///   1. Telemetry-derived defaults (`CurlRomDefaults`) — uses telemetry-tuned
  ///      looseness deltas via `_applyTelemetrySensitivity`.
  ///   2. Pipeline-derived defaults (SHELVED).
  ///   3. Legacy hand-tuned constants — uses the Tier-3 looseness deltas via
  ///      `applySensitivity`.
  ///
  /// For the diagnostic short-circuit that needs unmodified globals (sensitivity
  /// not applied), use [globalUnmodified].
  factory RomThresholds.global([
    CurlCameraView view = CurlCameraView.unknown,
    FeedbackSensitivity sensitivity = FeedbackSensitivity.medium,
  ]) {
    // Tier 1 — telemetry-derived defaults. Returns the strict (High-anchored)
    // tuple; sensitivity is applied via telemetry-specific deltas.
    if (kUseTelemetryRomDefaults) {
      final telemetry = CurlRomDefaults.forView(view);
      if (telemetry != null) {
        final highAnchor = RomThresholds(
          startAngle: telemetry.startAngle,
          peakAngle: telemetry.peakAngle,
          peakExitAngle: telemetry.peakExitAngle,
          endAngle: telemetry.endAngle,
          source: ThresholdSource.global,
        );
        return highAnchor._applyTelemetrySensitivity(sensitivity);
      }
    }
    // Tier 2 — pipeline-derived defaults (SHELVED). Tier-3 looseness applied.
    if (kUsePipelineRomDefaults) {
      final set = PipelineRomDefaults.forView(view);
      final highAnchor = RomThresholds(
        startAngle: set.startAngle,
        peakAngle: set.peakAngle,
        peakExitAngle: set.peakExitAngle,
        endAngle: set.endAngle,
        source: ThresholdSource.global,
      );
      return highAnchor.applySensitivity(sensitivity);
    }
    // Tier 3 — legacy hand-tuned constants. These are today's Medium-baseline
    // values; the High anchor is derived from them via the Tier-3 deltas
    // inverted so applying `(-5, +10, 0)` on Medium reproduces today exactly.
    final tier3HighAnchor = const RomThresholds(
      startAngle: kCurlStartAngle + 5.0,
      peakAngle: kCurlPeakAngle - 10.0,
      peakExitAngle: kCurlPeakExitAngle - 10.0,
      endAngle: kCurlEndAngle + 0.0,
      source: ThresholdSource.global,
    );
    return tier3HighAnchor.applySensitivity(sensitivity);
  }

  /// Cold-start globals with **no sensitivity post-pass**. Used by the
  /// diagnostic short-circuit (`diagnosticDisableAutoCalibration`) — applying
  /// sensitivity there would bias the baseline that the offline Python
  /// derivation script consumes, making measurements circular.
  ///
  /// Returns the Tier-3 Medium-baseline tuple (today's `kCurl*Angle` numbers
  /// unchanged) to preserve the diagnostic workflow contract bit-for-bit.
  factory RomThresholds.globalUnmodified([
    CurlCameraView view = CurlCameraView.unknown,
  ]) {
    // Diagnostic mode keeps reading from the legacy hand-tuned constants —
    // they're what the Python tuning workflow was calibrated against. We
    // deliberately bypass Tier-1 / Tier-2 here so the baseline is stable
    // across telemetry-derivation iterations.
    return const RomThresholds(
      startAngle: kCurlStartAngle,
      peakAngle: kCurlPeakAngle,
      peakExitAngle: kCurlPeakExitAngle,
      endAngle: kCurlEndAngle,
      source: ThresholdSource.global,
    );
  }

  /// Derives thresholds from a populated bucket. Returns the **High-anchored**
  /// tuple — apply `.applySensitivity(...)` at the call site for Medium users.
  ///
  /// Raw math:
  ///   peakAngle     = observedMinAngle + kProfilePeakTolerance  × m
  ///   peakExitAngle = peakAngle + kCurlPeakExitGap
  ///   startAngle    = observedMaxAngle − kProfileStartTolerance × m
  ///   endAngle      = observedMaxAngle − kProfileEndTolerance   × m
  ///
  /// FSM-completability invariants applied after the raw math:
  ///   1. endAngle  ≥ peakExitAngle + kCurlPeakExitGap   → ECCENTRIC can finish
  ///   2. startAngle ≥ peakAngle    + kCurlPeakExitGap   → CONCENTRIC can begin
  ///
  /// `m` = kProfileWarmupMultiplier when [warmup] is true, else 1.0.
  factory RomThresholds.fromBucket(
    RomBucketLike bucket, {
    bool warmup = false,
  }) {
    return _build(
      bucket: bucket,
      multiplier: warmup ? kProfileWarmupMultiplier : 1.0,
      source: warmup ? ThresholdSource.warmup : ThresholdSource.calibrated,
    );
  }

  /// Same math as [fromBucket] but tagged as auto-calibrated. Returns the
  /// **High-anchored** tuple — apply `.applySensitivity(...)` at the call
  /// site for Medium users.
  factory RomThresholds.autoCalibrated(RomBucketLike bucket) {
    return _build(
      bucket: bucket,
      multiplier: 1.0,
      source: ThresholdSource.autoCalibrated,
    );
  }

  static RomThresholds _build({
    required RomBucketLike bucket,
    required double multiplier,
    required ThresholdSource source,
  }) {
    final peak = bucket.observedMinAngle + kProfilePeakTolerance * multiplier;
    final peakExit = peak + kCurlPeakExitGap;
    final rawStart =
        bucket.observedMaxAngle - kProfileStartTolerance * multiplier;
    final rawEnd = bucket.observedMaxAngle - kProfileEndTolerance * multiplier;
    final start = rawStart > peak + kCurlPeakExitGap
        ? rawStart
        : peak + kCurlPeakExitGap;
    final end = rawEnd > peakExit + kCurlPeakExitGap
        ? rawEnd
        : peakExit + kCurlPeakExitGap;
    return RomThresholds(
      startAngle: start,
      peakAngle: peak,
      peakExitAngle: peakExit,
      endAngle: end,
      source: source,
    );
  }

  @override
  String toString() =>
      'RomThresholds(start=${startAngle.toStringAsFixed(1)}, '
      'peak=${peakAngle.toStringAsFixed(1)}, '
      'peakExit=${peakExitAngle.toStringAsFixed(1)}, '
      'end=${endAngle.toStringAsFixed(1)}, '
      'src=${source.name})';
}
