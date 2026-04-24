// GENERATED FILE — DO NOT EDIT BY HAND.
// Source: tools/dataset_analysis/scripts/generate_dart_v2.py
// Regenerate with: python -m scripts.generate_dart_v2
// Input: tools/dataset_analysis/data/derived/thresholds_v2.json


/// ═══════════════════════════════════════════════════════════════════
/// Data-driven default ROM thresholds for the biceps-curl FSM (v2).
/// ═══════════════════════════════════════════════════════════════════
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
///   clips. This is expected for (view, side) heterogeneity and
///   is the reason thresholds are bucketed rather than pooled.
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

/// Immutable view-specific threshold tuple returned by
/// [DefaultRomThresholds.forView]. Shape mirrors the four gates of the
/// biceps-curl FSM so consumers can destructure without imports.
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

/// Per-view biceps-curl threshold buckets.
///
/// Each bucket contains four FSM gates (start, peak, peakExit,
/// end) plus BCa 95% CIs, effective-n, and ICC for transparency.
/// Pick the correct bucket at runtime via [DefaultRomThresholds.forView].
class DefaultRomThresholds {
  const DefaultRomThresholds._();

  /// Hysteresis gap: peakExit = peakAngle + this (mirrors kCurlPeakExitGap).
  static const double peakExitGap = 15.0;

  // ── front (front, both) — n=9 reps, 1 clip(s) ─────────────────
  /// Data-driven safety margin: 5.00°.

  /// P20 Harrell-Davis – 5.00° safety.
  /// BCa 95% CI: [172.44, 173.38]  eff_n=9  ICC=0.000  outliers_rejected=0.
  static const double frontStartAngle = 172.94;

  /// P75 Harrell-Davis + 5.00° safety.
  /// BCa 95% CI: [19.02, 21.86]  eff_n=8  ICC=0.000  outliers_rejected=1.
  static const double frontPeakAngle = 19.75;

  /// Derived: peakAngle + peakExitGap.
  static const double frontPeakExitAngle = 34.75;

  /// FSM-safe: post-rep extension overshoots rep start by a
  /// sub-degree margin in the raw data, so we set the rep-end
  /// gate to min(start_p20, end_p20) - margin - 1° to preserve
  /// the start > end invariant. See derive_thresholds_v2.py.
  /// BCa 95% CI: [166.44, 167.38]  eff_n=9  ICC=0.000  outliers_rejected=0.
  static const double frontEndAngle = 171.94;

  // ── sideLeft (side, left) — n=4 reps, 1 clip(s) ─────────────────
  /// Data-driven safety margin: 5.00°.

  /// P20 Harrell-Davis – 5.00° safety.
  /// BCa 95% CI: [143.49, 144.84]  eff_n=4  ICC=0.000  outliers_rejected=1.
  static const double sideLeftStartAngle = 143.85;

  /// P75 Harrell-Davis + 5.00° safety.
  /// BCa 95% CI: [57.65, 60.45]  eff_n=5  ICC=0.000  outliers_rejected=0.
  static const double sideLeftPeakAngle = 59.62;

  /// Derived: peakAngle + peakExitGap.
  static const double sideLeftPeakExitAngle = 74.62;

  /// FSM-safe: post-rep extension overshoots rep start by a
  /// sub-degree margin in the raw data, so we set the rep-end
  /// gate to min(start_p20, end_p20) - margin - 1° to preserve
  /// the start > end invariant. See derive_thresholds_v2.py.
  /// BCa 95% CI: [137.49, 138.84]  eff_n=3  ICC=0.000  outliers_rejected=2.
  static const double sideLeftEndAngle = 142.85;

  /// Look up the threshold tuple for a given camera view.
  ///
  /// Returns a [CurlRomThresholdSet] containing the four FSM gates
  /// plus metadata. Falls back to [CurlCameraView.sideRight] values
  /// for [CurlCameraView.unknown] since side-view is the most
  /// anatomically-accurate projection.
  static CurlRomThresholdSet forView(CurlCameraView view) {
    switch (view) {
      case CurlCameraView.front:
        return const CurlRomThresholdSet(
          startAngle: frontStartAngle,
          peakAngle: frontPeakAngle,
          peakExitAngle: frontPeakExitAngle,
          endAngle: frontEndAngle,
        );
      case CurlCameraView.sideLeft:
        return const CurlRomThresholdSet(
          startAngle: sideLeftStartAngle,
          peakAngle: sideLeftPeakAngle,
          peakExitAngle: sideLeftPeakExitAngle,
          endAngle: sideLeftEndAngle,
        );
      case CurlCameraView.unknown:
        // Unknown view — fall back to the most anatomically
        // accurate bucket (side-view) until detection settles.
        return const CurlRomThresholdSet(
          startAngle: sideLeftStartAngle,
          peakAngle: sideLeftPeakAngle,
          peakExitAngle: sideLeftPeakExitAngle,
          endAngle: sideLeftEndAngle,
        );
      case CurlCameraView.sideRight:
        // sideRight mirrors sideLeft by bilateral biomechanical
        // symmetry: the elbow angle geometry of a curl is identical
        // across left/right sides in healthy subjects, and the 2D
        // projection of a side-view curl is a mirror image across
        // the sagittal plane — angular values are unchanged.
        // Recording a dedicated right-side clip would only be worth
        // it for handedness-specific ROM asymmetries (~2-5° in some
        // studies), which is below the 5° safety margin anyway.
        return const CurlRomThresholdSet(
          startAngle: sideLeftStartAngle,
          peakAngle: sideLeftPeakAngle,
          peakExitAngle: sideLeftPeakExitAngle,
          endAngle: sideLeftEndAngle,
        );
    }
  }
}
