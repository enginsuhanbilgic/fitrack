/// Per-rep FSM thresholds resolved from a profile bucket, the auto-calibrator,
/// or the global constants. Pure value object — no I/O, no mutation.
///
/// The FSM consumes one of these per rep and the source is locked at
/// IDLE→CONCENTRIC; it never swaps mid-rep (see plan invariant).
library;

import 'constants.dart';
import 'default_rom_thresholds.dart';
import 'manual_rom_overrides.dart';
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

  /// Returns the cold-start / [ThresholdSource.global] threshold set.
  ///
  /// [sensitivity] is applied only on this path — calibrated and auto-calibrated
  /// thresholds are personal and are never modified by sensitivity. Defaults to
  /// [CurlSensitivity.medium] so all existing callers compile unchanged.
  ///
  /// Three-tier resolver, sensitivity-aware:
  ///   1. Manual override — sensitivity selects the strict/default/permissive
  ///      constant directly (no delta math needed).
  ///   2. Data-driven generated — sensitivity deltas applied via
  ///      [_applyRomSensitivity] after derivation.
  ///   3. Legacy hand-tuned constants — same delta application.
  factory RomThresholds.global([
    CurlCameraView view = CurlCameraView.unknown,
    CurlSensitivity sensitivity = CurlSensitivity.medium,
  ]) {
    // Tier 1 — manual override (sensitivity-aware; each level is a separate constant).
    if (kUseManualOverrides) {
      final override = ManualRomOverrides.forView(view, sensitivity);
      if (override != null) {
        return RomThresholds(
          startAngle: override.startAngle,
          peakAngle: override.peakAngle,
          peakExitAngle: override.peakExitAngle,
          endAngle: override.endAngle,
          source: ThresholdSource.global,
        );
      }
    }
    // Tier 2 — data-driven generated defaults; apply sensitivity deltas.
    if (kUseDataDrivenThresholds) {
      final set = DefaultRomThresholds.forView(view);
      return _applyRomSensitivity(
        RomThresholds(
          startAngle: set.startAngle,
          peakAngle: set.peakAngle,
          peakExitAngle: set.peakExitAngle,
          endAngle: set.endAngle,
          source: ThresholdSource.global,
        ),
        sensitivity,
        view,
      );
    }
    // Tier 3 — legacy hand-tuned constants; apply sensitivity deltas.
    return _applyRomSensitivity(
      const RomThresholds(
        startAngle: kCurlStartAngle,
        peakAngle: kCurlPeakAngle,
        peakExitAngle: kCurlPeakExitAngle,
        endAngle: kCurlEndAngle,
        source: ThresholdSource.global,
      ),
      sensitivity,
      view,
    );
  }

  /// Applies additive ROM deltas for a sensitivity level to a base threshold set.
  ///
  /// FSM invariant (start > end > peakExit > peak) is re-verified and floors
  /// applied so the invariant always holds regardless of input.
  /// peakExitAngle is always re-derived from the adjusted peak + kCurlPeakExitGap.
  static RomThresholds _applyRomSensitivity(
    RomThresholds base,
    CurlSensitivity sensitivity, [
    CurlCameraView view = CurlCameraView.unknown,
  ]) {
    if (sensitivity == CurlSensitivity.medium) return base;
    // ROM deltas: (dStart, dPeak, dEnd)
    // High: tighter gates — must curl deeper and extend more fully.
    final (dStart, dPeak, dEnd) = switch (sensitivity) {
      CurlSensitivity.high => (5.0, -10.0, 0.0),
      CurlSensitivity.medium => (0.0, 0.0, 0.0), // unreachable; guarded above
    };
    final peak = base.peakAngle + dPeak;
    final start = base.startAngle + dStart;
    final end = base.endAngle + dEnd;
    final peakExit = peak + kCurlPeakExitGap;
    // Invariant floors: start > end > peakExit > peak
    final safeEnd = end > peakExit + kCurlPeakExitGap
        ? end
        : peakExit + kCurlPeakExitGap;
    final safeStart = start > safeEnd ? start : safeEnd + 1.0;
    return RomThresholds(
      startAngle: safeStart,
      peakAngle: peak,
      peakExitAngle: peakExit,
      endAngle: safeEnd,
      source: base.source,
    );
  }

  /// Derives thresholds from a populated bucket.
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
  /// Without these invariants a restricted-ROM bucket (e.g. min=90°, max=130°)
  /// produces `end ≤ peakExit` — the FSM enters PEAK and never leaves. Floor
  /// keeps the user counting; bucket sample acceptance gating
  /// (`kMinViableRomDegrees`) is the *separate* concern of profile updates.
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

  /// Same math as [fromBucket] but tagged as auto-calibrated. Kept as a
  /// separate factory so the source is explicit at the call site.
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
    // Floors guarantee the FSM is always completable.
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
