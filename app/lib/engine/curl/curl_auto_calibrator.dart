/// Transient in-set ROM estimator used when no calibrated bucket exists.
///
/// Builds a `RomThresholds.autoCalibrated` after observing ≥ 2 reps with a
/// usable ROM excursion. State is reset at the start of every set and on any
/// view-lock change — both events imply the previously-observed range may no
/// longer apply.
///
/// ANCHORING (2026-05-15)
/// ──────────────────────
/// Pre-2026-05-15 the calibrator anchored thresholds on the **running mean**
/// of MAD-accepted min/max samples. That had a structural flaw: shallow reps
/// drifted the mean shallow, which loosened the threshold, which let even
/// more shallow reps pass — auto-cal silently drifted with form decay
/// instead of holding the user to their demonstrated ability.
///
/// Post-2026-05-15 the anchor is the **min/max of the MAD-accepted rolling
/// window** (`kProfileOutlierWindow` = 8 reps deep):
///   * `peakAngle` anchor  = min(_minSamples) → user's deepest demonstrated rep
///   * `start/endAngle` anchor = max(_maxSamples) → user's most extended demonstrated rep
///
/// Margins (`kProfilePeakTolerance` etc.) follow the shared constants — as of
/// the 2026-05-16 halving the bands are +7.5° / −5° / −12.5°; only the anchor
/// moves from "average" to "demonstrated best within recent window."
/// Rolling-window (not absolute-session) so genuine fatigue across a long set
/// gradually relaxes the anchor — early-set PRs don't lock the threshold
/// forever.
library;

import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/rom_thresholds.dart';
import 'mad_outlier.dart' as mad;

class _AutoBucket implements RomBucketLike {
  @override
  double observedMinAngle;
  @override
  double observedMaxAngle;
  _AutoBucket(this.observedMinAngle, this.observedMaxAngle);
}

class CurlAutoCalibrator {
  int _repCount = 0;

  /// Per-dimension windows feeding both MAD outlier rejection AND the
  /// min/max anchor calculation. Bounded by `kProfileOutlierWindow`.
  /// Post-2026-05-15: `currentThresholds` reads min/max of these directly
  /// instead of a parallel running average.
  final List<double> _minSamples = [];
  final List<double> _maxSamples = [];

  /// Add one rep's extremes. Each dimension is filtered independently through
  /// MAD outlier rejection — a rep with a new deepest flexion (valid PR) may
  /// still pair with a normal rest angle, so rejecting both in lockstep would
  /// discard bucket-expanding data. `_repCount` advances when at least one
  /// dimension was kept.
  void recordRepExtremes(double min, double max) {
    final minOutlier = mad.isMadOutlier(_minSamples, min);
    final maxOutlier = mad.isMadOutlier(_maxSamples, max);

    if (!minOutlier) {
      _appendRecent(_minSamples, min);
    }

    if (!maxOutlier) {
      _appendRecent(_maxSamples, max);
    }

    if (!minOutlier || !maxOutlier) {
      _repCount++;
    }
  }

  static void _appendRecent(List<double> buf, double v) {
    buf.add(v);
    if (buf.length > kProfileOutlierWindow) buf.removeAt(0);
  }

  /// Emits thresholds when conditions are met:
  ///   - ≥ 2 reps observed
  ///   - Both sample windows non-empty
  ///   - ROM excursion (max − min) ≥ kMinViableRomDegrees
  /// Otherwise null — caller should fall back to globals.
  ///
  /// Anchor is the **deepest** observed min and **most extended** observed
  /// max within the rolling window (NOT the running mean — see file-level
  /// ANCHORING doc-block).
  RomThresholds? get currentThresholds {
    if (_repCount < 2) return null;
    if (_minSamples.isEmpty || _maxSamples.isEmpty) return null;
    final minBest = _minSamples.reduce(math.min);
    final maxBest = _maxSamples.reduce(math.max);
    final rom = maxBest - minBest;
    if (rom < kMinViableRomDegrees) return null;
    return RomThresholds.autoCalibrated(_AutoBucket(minBest, maxBest));
  }

  int get repCount => _repCount;

  /// Per-set / per-view-lock reset. The previously-observed extremes no longer
  /// apply because the user has either rested (set boundary) or the camera
  /// frame changed (view boundary).
  void reset() {
    _repCount = 0;
    _minSamples.clear();
    _maxSamples.clear();
  }
}
