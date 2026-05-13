// GENERATED FILE — DO NOT EDIT BY HAND.
// Source: tools/dataset_analysis/scripts/generate_dart_v2.py
// Regenerate with: python -m scripts.generate_dart_v2
// Input: tools/dataset_analysis/data/derived/thresholds_v2.json

/// ═══════════════════════════════════════════════════════════════════
/// SHELVED — Pipeline-derived ROM threshold defaults for the curl FSM.
/// ═══════════════════════════════════════════════════════════════════
///
/// PROJECT CONVENTION (2026-05-13)
/// ───────────────────────────────
/// This file represents the **shelved alternative** to FiTrack's canonical
/// telemetry-derived curl defaults (`curl_rom_defaults.dart`). It is built
/// by an offline statistical pipeline that consumes recorded video clips
/// (`tools/dataset_analysis/data/videos/`) and emits per-(view, side)
/// threshold buckets here.
///
/// At runtime this file is NOT consumed unless `kUsePipelineRomDefaults`
/// is flipped to `true`. It is preserved (a) so the cross-validation
/// metadata stays visible for future analysis, and (b) so a one-character
/// flag flip re-enables the pipeline once the recorded dataset is large
/// and diverse enough to produce stable thresholds.
///
/// Why it is shelved: leave-one-clip-out cross-validation on the current
/// 6-clip / 14-good-rep dataset showed std swings of ±20–28° per gate —
/// thresholds do not generalize across clips. The shipping path uses
/// telemetry-derived defaults instead (`CurlRomDefaults`).
///
/// Three-tier resolver precedence (see `rom_thresholds.dart`):
///   1. Telemetry-derived curl defaults (`curl_rom_defaults.dart`)        ★ shipping
///   2. Pipeline-derived defaults   (this file, gated)                      shelved
///   3. Legacy hand-tuned constants (`constants.dart`)                      fallback
///
/// METHODOLOGY
/// ───────────
/// • Percentile estimator:  Harrell-Davis (Harrell & Davis, 1982)
/// • Confidence interval:   BCa bootstrap (Efron & Tibshirani, 1993)
///   — 10000 resamples, seed=1234
/// • Outlier rejection:     MAD-based, threshold 3.5 (Leys et al., 2013)
/// • Safety margin:         Data-driven 2σ rest-noise floor (MAD-scaled)
/// • Cluster correction:    Design effect via ICC (Kish, 1965)
/// • Cross-validation:      Leave-one-clip-out
/// • Bucketing strategy:    Per (view, side) — mirrors shipping CurlRomProfile
///
/// DATASET
/// ───────
/// • Good reps:             14
/// • Total rep rows:        63
/// • Good clips:            2
/// • Total clips:           6
///
/// LEAVE-ONE-CLIP-OUT CROSS-VALIDATION
/// ─────────────────────────────────
///   start P20:  163.48° ± 20.45°
///   peak  P75:  34.59° ± 28.32°
///   end   P20:  161.67° ± 23.18°
///
///   High std across folds = thresholds don't generalize across
///   clips. This is the reason the file is shelved in favor of
///   telemetry-derived defaults.
///
/// CITATIONS
/// ─────────
///   Harrell, F.E. & Davis, C.E. (1982). A new distribution-free
///     quantile estimator. Biometrika, 69(3), 635–640.
///   Efron, B. & Tibshirani, R.J. (1993). An Introduction to the
///     Bootstrap. Chapman & Hall.
///   Leys, C., Ley, C., Klein, O., Bernard, P. & Licata, L. (2013).
///     Detecting outliers: Do not use standard deviation around
///     the mean, use absolute deviation around the median. JESP,
///     49(4), 764–766.
///   Kish, L. (1965). Survey Sampling. Wiley.
/// ═══════════════════════════════════════════════════════════════════
library;

import 'types.dart';

/// Immutable view-specific threshold tuple. Shared output type used by both
/// the telemetry and pipeline tiers so the resolver consumes them identically.
class CurlRomThresholdSet {
  const CurlRomThresholdSet({
    required this.startAngle,
    required this.peakAngle,
    required this.peakExitAngle,
    required this.endAngle,
  });

  final double startAngle;
  final double peakAngle;
  final double peakExitAngle;
  final double endAngle;
}

/// Per-view biceps-curl pipeline-derived threshold buckets.
///
/// Each bucket contains four FSM gates (start, peak, peakExit, end). Not read
/// at runtime unless [kUsePipelineRomDefaults] is `true`.
class PipelineRomDefaults {
  const PipelineRomDefaults._();

  /// Hysteresis gap: peakExit = peakAngle + this (mirrors kCurlPeakExitGap).
  static const double peakExitGap = 15.0;

  // Front-view constants removed 2026-05 along with front-view analysis.
  // The `CurlCameraView.front` enum value is retained as a view-detector
  // fallback sentinel; the `forView` resolver below maps it to side-view
  // thresholds.

  // ── sideLeft (side, left) — bootstrapped from 2026-04-28 --from-frames run ──
  // Derived from frame-signal detection (local-min/max on angle_raw series),
  // n=5 reps after 3.5×MAD rejection. Personal medians: peak=108.4°, start=167.0°.
  // These mirror the telemetry-derived defaults (medium) in
  // `curl_rom_defaults.dart`; the telemetry tier takes precedence when
  // kUseTelemetryRomDefaults=true, so in practice this bucket is only used
  // when telemetry defaults are disabled.
  static const double sideLeftStartAngle = 159.0;
  static const double sideLeftPeakAngle = 136.4;

  /// Derived: peakAngle + peakExitGap.
  static const double sideLeftPeakExitAngle = 151.4;

  static const double sideLeftEndAngle = 156.4;

  // ── sideRight (bilateral mirror of sideLeft) ─────────────────────────────
  // handcrafted extension — survives regeneration (forView() is also
  // hand-written and not emitted by generate_dart_v2.py).
  //
  // Angular values are identical to sideLeft by bilateral biomechanical
  // symmetry: the elbow-angle geometry of a curl is identical across
  // left/right sides in healthy subjects. The 2D sagittal projection is a
  // mirror image — angular magnitudes are unchanged. A dedicated right-side
  // recording would only improve results for handedness-specific ROM
  // asymmetries (~2–5° per literature), which falls within the existing
  // 5° safety margin. These constants are aliases, not copies — changing
  // the sideLeft source values automatically propagates here.
  static const double sideRightStartAngle = sideLeftStartAngle;
  static const double sideRightPeakAngle = sideLeftPeakAngle;
  static const double sideRightPeakExitAngle = sideLeftPeakExitAngle;
  static const double sideRightEndAngle = sideLeftEndAngle;

  /// Look up the threshold tuple for a given camera view.
  ///
  /// Returns a [CurlRomThresholdSet] containing the four FSM gates
  /// plus metadata. Falls back to [CurlCameraView.sideRight] values
  /// for [CurlCameraView.unknown] since side-view is the most
  /// anatomically-accurate projection.
  static CurlRomThresholdSet forView(CurlCameraView view) {
    switch (view) {
      case CurlCameraView.front:
        // Front view removed 2026-05. The enum value is retained as a
        // view-detector fallback sentinel only; if it ever reaches this
        // resolver, fall back to side-view thresholds (most anatomically
        // accurate 2D projection).
        return const CurlRomThresholdSet(
          startAngle: sideRightStartAngle,
          peakAngle: sideRightPeakAngle,
          peakExitAngle: sideRightPeakExitAngle,
          endAngle: sideRightEndAngle,
        );
      case CurlCameraView.sideLeft:
        return const CurlRomThresholdSet(
          startAngle: sideLeftStartAngle,
          peakAngle: sideLeftPeakAngle,
          peakExitAngle: sideLeftPeakExitAngle,
          endAngle: sideLeftEndAngle,
        );
      case CurlCameraView.unknown:
        // Falls back to side-view (most anatomically accurate 2D projection)
        // until the view detector settles.
        return const CurlRomThresholdSet(
          startAngle: sideRightStartAngle, // same value as sideLeft
          peakAngle: sideRightPeakAngle,
          peakExitAngle: sideRightPeakExitAngle,
          endAngle: sideRightEndAngle,
        );
      case CurlCameraView.sideRight:
        return const CurlRomThresholdSet(
          startAngle: sideRightStartAngle,
          peakAngle: sideRightPeakAngle,
          peakExitAngle: sideRightPeakExitAngle,
          endAngle: sideRightEndAngle,
        );
    }
  }
}
