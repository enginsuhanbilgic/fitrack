/// Transient in-set ROM estimator for squat, used when no calibrated
/// [SquatRomProfile] bucket exists yet.
///
/// Builds a [SquatRomThresholdSet] after observing ≥ 2 reps with a usable
/// ROM excursion. State is reset at the start of every set — squat has no
/// view-lock concept so there is no view-flip reset path.
///
/// Verbatim mirror of `curl_auto_calibrator.dart`'s API + behavior, with
/// squat-typed return values. Documented as a deliberate mirror: if either
/// implementation is fixed, fix both. A future refactor into a generic
/// `RomAutoCalibrator<T>` is an acknowledged but deferred opportunity.
library;

import '../../core/constants.dart';
import '../../core/squat_rom_defaults.dart';
import '../curl/mad_outlier.dart' as mad_local;

class SquatAutoCalibrator {
  /// Running average of the deepest knee flexion seen each rep.
  double? _minAvg;

  /// Running average of the most extended knee angle seen each rep.
  double? _maxAvg;

  int _repCount = 0;
  int _minAcceptedCount = 0;
  int _maxAcceptedCount = 0;

  /// Per-dimension windows feeding MAD outlier rejection. Bounded by
  /// [kProfileOutlierWindow] — same window size [SquatRomBucket] uses.
  final List<double> _minSamples = [];
  final List<double> _maxSamples = [];

  /// Record one rep's extremes. Each dimension is filtered independently
  /// through MAD outlier rejection — a rep that produces a new deepest
  /// squat angle may pair with a perfectly normal standing-extension angle,
  /// so rejecting both in lockstep would discard bucket-expanding data.
  /// Only accepted samples update the running average; [_repCount] advances
  /// when at least one dimension was kept.
  void recordRepExtremes(double min, double max) {
    final minOutlier = mad_local.isMadOutlier(_minSamples, min);
    final maxOutlier = mad_local.isMadOutlier(_maxSamples, max);

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
  ///   - ROM excursion (max − min) ≥ [kSquatMinViableRomDegrees]
  /// Otherwise null — caller should fall back to globals.
  SquatRomThresholdSet? get currentThresholds {
    if (_repCount < 2) return null;
    final rom = _maxAvg! - _minAvg!;
    if (rom < kSquatMinViableRomDegrees) return null;
    return SquatRomThresholdSet.fromBucket(
      observedMinKneeAngle: _minAvg!,
      observedMaxKneeAngle: _maxAvg!,
    );
  }

  int get repCount => _repCount;

  /// Per-set reset. Squat has no view-lock concept, so this is set-only —
  /// the previously-observed range may no longer apply because the user has
  /// rested between sets and their depth/extension may shift.
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
