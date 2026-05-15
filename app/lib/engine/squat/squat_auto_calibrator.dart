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
///
/// ANCHORING (2026-05-15)
/// ──────────────────────
/// Pre-2026-05-15 the calibrator anchored thresholds on the running mean of
/// MAD-accepted min/max samples — structural drift: shallow reps loosened
/// the threshold which let more shallow reps pass.
///
/// Post-2026-05-15 the anchor is the deepest / most-extended sample within
/// the MAD-accepted rolling window ([kProfileOutlierWindow] = 8 reps):
///   * bottomAngle anchor = min(_minSamples) → user's deepest demonstrated rep
///   * startAngle / endAngle anchor = max(_maxSamples) → user's most extended rep
///
/// Margins inside [SquatRomThresholdSet.fromBucket] are UNCHANGED — only the
/// anchor moves from "average" to "demonstrated best within recent window."
/// Rolling-window so genuine fatigue across a long set gradually relaxes the
/// anchor.
library;

import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/squat_rom_defaults.dart';
import '../curl/mad_outlier.dart' as mad_local;

class SquatAutoCalibrator {
  int _repCount = 0;

  /// Per-dimension windows feeding both MAD outlier rejection AND the
  /// min/max anchor calculation. Bounded by [kProfileOutlierWindow].
  /// Post-2026-05-15: `currentThresholds` reads min/max of these directly
  /// instead of a parallel running average.
  final List<double> _minSamples = [];
  final List<double> _maxSamples = [];

  /// Record one rep's extremes. Each dimension is filtered independently
  /// through MAD outlier rejection — a rep that produces a new deepest
  /// squat angle may pair with a perfectly normal standing-extension angle,
  /// so rejecting both in lockstep would discard bucket-expanding data.
  /// [_repCount] advances when at least one dimension was kept.
  void recordRepExtremes(double min, double max) {
    final minOutlier = mad_local.isMadOutlier(_minSamples, min);
    final maxOutlier = mad_local.isMadOutlier(_maxSamples, max);

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
  ///   - ROM excursion (max − min) ≥ [kSquatMinViableRomDegrees]
  /// Otherwise null — caller should fall back to globals.
  ///
  /// Anchor is the deepest observed min and most-extended observed max
  /// within the rolling window (NOT the running mean — see file-level
  /// ANCHORING doc-block).
  SquatRomThresholdSet? get currentThresholds {
    if (_repCount < 2) return null;
    if (_minSamples.isEmpty || _maxSamples.isEmpty) return null;
    final minBest = _minSamples.reduce(math.min);
    final maxBest = _maxSamples.reduce(math.max);
    final rom = maxBest - minBest;
    if (rom < kSquatMinViableRomDegrees) return null;
    return SquatRomThresholdSet.fromBucket(
      observedMinKneeAngle: minBest,
      observedMaxKneeAngle: maxBest,
    );
  }

  int get repCount => _repCount;

  /// Per-set reset. Squat has no view-lock concept, so this is set-only —
  /// the previously-observed range may no longer apply because the user has
  /// rested between sets and their depth/extension may shift.
  void reset() {
    _repCount = 0;
    _minSamples.clear();
    _maxSamples.clear();
  }
}
