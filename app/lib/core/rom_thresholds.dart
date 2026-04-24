/// Per-rep FSM thresholds resolved from a profile bucket, the auto-calibrator,
/// or the global constants. Pure value object — no I/O, no mutation.
///
/// The FSM consumes one of these per rep and the source is locked at
/// IDLE→CONCENTRIC; it never swaps mid-rep (see plan invariant).
library;

import 'constants.dart';
import 'default_rom_thresholds.dart';
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

  /// Returns the cold-start / `ThresholdSource.global` threshold set.
  ///
  /// Two code paths, selected by the [kUseDataDrivenThresholds] flag in
  /// `constants.dart`:
  ///
  ///   * **Flag `false` (default, current shipping behavior):** returns the
  ///     hand-tuned legacy constants (`kCurlStartAngle`, `kCurlPeakAngle`,
  ///     `kCurlPeakExitAngle`, `kCurlEndAngle`). [view] is ignored. Behavior
  ///     is identical to pre-T2.4 FiTrack.
  ///   * **Flag `true`:** returns the T2.4-derived per-view bucket from
  ///     [DefaultRomThresholds.forView], keyed on [view]. Falls back to
  ///     [CurlCameraView.unknown] if no view is supplied (which itself
  ///     routes to the side-view bucket as the most anatomically accurate
  ///     projection — see `default_rom_thresholds.dart`).
  ///
  /// [view] is optional so existing callers (tests, initializers, fallback
  /// paths where view hasn't been detected yet) continue to compile unchanged.
  /// Once the flag is flipped to `true`, callers that can supply the real
  /// view should — otherwise they default to the side-view bucket.
  factory RomThresholds.global([CurlCameraView view = CurlCameraView.unknown]) {
    if (kUseDataDrivenThresholds) {
      final set = DefaultRomThresholds.forView(view);
      return RomThresholds(
        startAngle: set.startAngle,
        peakAngle: set.peakAngle,
        peakExitAngle: set.peakExitAngle,
        endAngle: set.endAngle,
        source: ThresholdSource.global,
      );
    }
    return const RomThresholds(
      startAngle: kCurlStartAngle,
      peakAngle: kCurlPeakAngle,
      peakExitAngle: kCurlPeakExitAngle,
      endAngle: kCurlEndAngle,
      source: ThresholdSource.global,
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
