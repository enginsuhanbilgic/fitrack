/// Median Absolute Deviation (MAD) outlier rejection — shared utility.
///
/// Extracted from `curl_rom_profile.dart` in Phase 3 (F2) so the curl
/// auto-calibrator can reuse the same outlier logic without duplicating it.
///
/// Callers own the sample window (typically bounded by `kProfileOutlierWindow`).
library;

import '../../core/constants.dart';

/// True if `sample` is more than `kProfileMadThreshold × MAD` from the
/// median of the existing window.
///
/// Returns `false` when the window is too small (< 4) to compute a meaningful
/// MAD, or when MAD is 0 (a constant window is biologically valid data — any
/// deviation is technically "infinite MADs" but not an outlier).
bool isMadOutlier(List<double> window, double sample) {
  if (window.length < 4) return false;
  final sorted = List<double>.from(window)..sort();
  final med = median(sorted);
  final deviations = sorted.map((v) => (v - med).abs()).toList()..sort();
  final mad = median(deviations);
  if (mad == 0) return false;
  return (sample - med).abs() > kProfileMadThreshold * mad;
}

/// Median of an already-sorted list. Precondition: `sorted.isNotEmpty` and
/// `sorted` is ascending — both are caller responsibilities.
double median(List<double> sorted) {
  final n = sorted.length;
  if (n.isOdd) return sorted[n ~/ 2];
  return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
}
