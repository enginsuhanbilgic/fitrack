/// Transient in-set ROM estimator used when no calibrated bucket exists.
///
/// Builds a `RomThresholds.autoCalibrated` after observing ≥ 2 reps with a
/// usable ROM excursion. State is reset at the start of every set and on any
/// view-lock change — both events imply the previously-observed range may no
/// longer apply.
library;

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
  /// Running average of the deepest flexion seen each rep.
  double? _minAvg;

  /// Running average of the most extended angle seen each rep.
  double? _maxAvg;

  int _repCount = 0;
  int _minAcceptedCount = 0;
  int _maxAcceptedCount = 0;

  /// Per-dimension windows feeding MAD outlier rejection. Bounded by
  /// `kProfileOutlierWindow` — the same window size `RomBucket` uses.
  final List<double> _minSamples = [];
  final List<double> _maxSamples = [];

  /// Add one rep's extremes. Each dimension is filtered independently through
  /// MAD outlier rejection — a rep with a new deepest flexion (valid PR) may
  /// still pair with a normal rest angle, so rejecting both in lockstep would
  /// discard bucket-expanding data. Only accepted samples update the running
  /// average, and `_repCount` advances when at least one dimension was kept.
  void recordRepExtremes(double min, double max) {
    final minOutlier = mad.isMadOutlier(_minSamples, min);
    final maxOutlier = mad.isMadOutlier(_maxSamples, max);

    if (!minOutlier) {
      _minAcceptedCount++;
      if (_minAcceptedCount == 1) {
        _minAvg = min;
      } else {
        _minAvg = _minAvg! + (min - _minAvg!) / _minAcceptedCount;
      }
      _appendRecent(_minSamples, min);
    }

    if (!maxOutlier) {
      _maxAcceptedCount++;
      if (_maxAcceptedCount == 1) {
        _maxAvg = max;
      } else {
        _maxAvg = _maxAvg! + (max - _maxAvg!) / _maxAcceptedCount;
      }
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
  ///   - ROM excursion (max − min) ≥ kMinViableRomDegrees
  /// Otherwise null — caller should fall back to globals.
  RomThresholds? get currentThresholds {
    if (_repCount < 2) return null;
    final rom = _maxAvg! - _minAvg!;
    if (rom < kMinViableRomDegrees) return null;
    return RomThresholds.autoCalibrated(_AutoBucket(_minAvg!, _maxAvg!));
  }

  int get repCount => _repCount;

  /// Per-set / per-view-lock reset. The previously-averaged extremes no longer
  /// apply because the user has either rested (set boundary) or the camera
  /// frame changed (view boundary).
  void reset() {
    _minAvg = null;
    _maxAvg = null;
    _repCount = 0;
    _minAcceptedCount = 0;
    _maxAcceptedCount = 0;
    _minSamples.clear();
    _maxSamples.clear();
  }
}
