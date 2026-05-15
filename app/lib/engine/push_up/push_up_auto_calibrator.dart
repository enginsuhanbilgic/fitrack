/// Transient in-set ROM estimator for push-up, used when no calibrated
/// [PushUpRomProfile] exists yet.
///
/// Builds a [PushUpRomThresholds] after observing ≥ 2 reps with a usable
/// ROM excursion. State is reset at the start of every set — push-up has
/// no view-lock concept, mirroring squat.
///
/// Verbatim mirror of `curl_auto_calibrator.dart` and `squat_auto_calibrator.dart`
/// in shape, with push-up-typed return values. Documented as a deliberate
/// mirror: if either implementation is fixed, fix all three. A future
/// refactor into a generic `RomAutoCalibrator<T>` is an acknowledged but
/// deferred opportunity.
///
/// ANCHORING (2026-05-15)
/// ──────────────────────
/// Anchor is the deepest / most-extended sample within the MAD-accepted
/// rolling window ([kProfileOutlierWindow] = 8 reps):
///   * bottomAngle anchor = min(_bottomSamples) → user's deepest demonstrated rep
///   * startAngle / endAngle anchor = max(_topSamples) → user's most extended rep
///
/// The four FSM gates (start / bottom / shallowRepMax / end) are derived
/// from the (topBest, bottomBest) tuple using the SAME percentage-of-ROM
/// margin math that `PushUpRomProfile.thresholds` uses for the calibrated
/// path. This keeps tier-1 (calibrated) and tier-2 (auto-cal) thresholds
/// geometrically consistent — only the anchor source differs.
///
/// Rolling-window (not absolute-session) so genuine fatigue across a long
/// set gradually relaxes the anchor — early-set PRs don't lock the
/// threshold forever.
library;

import 'dart:math' as math;

import '../../core/constants.dart';
import '../curl/mad_outlier.dart' as mad;
import 'push_up_rom_profile.dart';

class PushUpAutoCalibrator {
  int _repCount = 0;

  /// Per-dimension windows feeding both MAD outlier rejection AND the
  /// min/max anchor calculation. Bounded by [kProfileOutlierWindow].
  /// `currentThresholds` reads max/min of these directly — no parallel
  /// running average is maintained.
  final List<double> _topSamples = [];
  final List<double> _bottomSamples = [];

  /// Record one rep's extremes. Each dimension is filtered independently
  /// through MAD outlier rejection — a rep that produces a new
  /// most-extended top angle may pair with a normal bottom, so rejecting
  /// both in lockstep would discard bucket-expanding data. [_repCount]
  /// advances when at least one dimension was kept.
  void recordRepExtremes(double topAngle, double bottomAngle) {
    final topOutlier = mad.isMadOutlier(_topSamples, topAngle);
    final bottomOutlier = mad.isMadOutlier(_bottomSamples, bottomAngle);

    if (!topOutlier) {
      _appendRecent(_topSamples, topAngle);
    }

    if (!bottomOutlier) {
      _appendRecent(_bottomSamples, bottomAngle);
    }

    if (!topOutlier || !bottomOutlier) {
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
  ///   - ROM excursion (topBest − bottomBest) ≥ [kPushUpMinViableRomDegrees]
  /// Otherwise null — caller should fall back to defaults.
  ///
  /// Anchor is the most-extended observed top and deepest observed bottom
  /// within the rolling window (NOT the running mean). Threshold
  /// derivation uses the same percentage-of-ROM margins as
  /// [PushUpRomProfile.thresholds] for tier-1/2 consistency.
  PushUpRomThresholds? get currentThresholds {
    if (_repCount < 2) return null;
    if (_topSamples.isEmpty || _bottomSamples.isEmpty) return null;
    final topBest = _topSamples.reduce(math.max);
    final bottomBest = _bottomSamples.reduce(math.min);
    final rom = topBest - bottomBest;
    if (rom < kPushUpMinViableRomDegrees) return null;

    // Reuse the calibrated-profile threshold derivation by constructing a
    // synthetic profile from the anchor. This guarantees auto-cal and
    // manual-cal produce geometrically identical thresholds when given
    // identical (topBest, bottomBest) — the only difference between the
    // two tiers is the *source* of those numbers, not the math that
    // turns them into gates. Regression-tested by
    // `test/engine/push_up/push_up_auto_calibrator_test.dart`.
    return PushUpRomProfile.calibrated(
      topAngle: topBest,
      bottomAngle: bottomBest,
    ).thresholds;
  }

  int get repCount => _repCount;

  /// Per-set reset. Push-up has no view-lock concept, so this is set-only
  /// — the previously-observed range may no longer apply because the
  /// user has rested between sets and their depth/extension may shift.
  void reset() {
    _repCount = 0;
    _topSamples.clear();
    _bottomSamples.clear();
  }
}
