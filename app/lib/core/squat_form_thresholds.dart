library;

import 'constants.dart';
import 'types.dart';

/// Injectable form-error thresholds for [SquatFormAnalyzer].
///
/// Mirrors [FormThresholds] for biceps curl. Decouples [SquatFormAnalyzer]
/// from global k* constants so tests and future sensitivity variants can
/// inject different values without recompiling.
class SquatFormThresholds {
  const SquatFormThresholds({
    required this.leanWarnDegBodyweight,
    required this.leanWarnDegHBBS,
    required this.longFemurLeanBoost,
    required this.kneeShiftWarnRatio,
    required this.heelLiftWarnRatio,
  });

  final double leanWarnDegBodyweight;
  final double leanWarnDegHBBS;
  final double longFemurLeanBoost;
  final double kneeShiftWarnRatio;
  final double heelLiftWarnRatio;

  /// Matches the current hard-coded constants exactly.
  /// Default for all callers until a squat sensitivity dial is introduced.
  static const SquatFormThresholds defaults = SquatFormThresholds(
    leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight,
    leanWarnDegHBBS: kSquatLeanWarnDegHBBS,
    longFemurLeanBoost: kSquatLongFemurLeanBoost,
    kneeShiftWarnRatio: kSquatKneeShiftWarnRatio,
    heelLiftWarnRatio: kSquatHeelLiftWarnRatio,
  );

  /// Builds thresholds for a given [SquatSensitivity] level.
  ///
  /// Additive deltas per metric (not a uniform multiplier) because lean (°),
  /// knee-shift (ratio ~0.30), and heel-lift (ratio ~0.03) live on incompatible
  /// scales. Deltas mirror the Python script's SQUAT_SENSITIVITIES block:
  ///   high   — lean −3°, shift −0.03, lift −0.005  (tighter gates)
  ///   medium — no delta                              (== defaults)
  ///   low    — lean +8°, shift +0.08, lift +0.012   (more permissive)
  factory SquatFormThresholds.forSensitivity(SquatSensitivity s) {
    final (leanDelta, shiftDelta, liftDelta) = switch (s) {
      SquatSensitivity.high => (-3.0, -0.03, -0.005),
      SquatSensitivity.medium => (0.0, 0.0, 0.0),
      SquatSensitivity.low => (8.0, 0.08, 0.012),
    };
    return SquatFormThresholds(
      leanWarnDegBodyweight: kSquatLeanWarnDegBodyweight + leanDelta,
      leanWarnDegHBBS: kSquatLeanWarnDegHBBS + leanDelta,
      longFemurLeanBoost: kSquatLongFemurLeanBoost,
      kneeShiftWarnRatio: kSquatKneeShiftWarnRatio + shiftDelta,
      heelLiftWarnRatio: kSquatHeelLiftWarnRatio + liftDelta,
    );
  }

  /// Effective lean threshold for a given variant + long-femur flag.
  double leanWarnFor(SquatVariant variant, {bool longFemur = false}) {
    final base = switch (variant) {
      SquatVariant.bodyweight => leanWarnDegBodyweight,
      SquatVariant.highBarBackSquat => leanWarnDegHBBS,
    };
    return base + (longFemur ? longFemurLeanBoost : 0.0);
  }
}
