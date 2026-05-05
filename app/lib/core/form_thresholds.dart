/// Injectable bundle of form-error thresholds for biceps curl.
///
/// Replaces direct reads of the 6 `k*` constants in both analyzers so a
/// single [CurlSensitivity] decision made in `WorkoutViewModel.init()` flows
/// down through CurlStrategy → RepCounter without any intermediate layer
/// needing to know about sensitivity. Pure value class — no Flutter dependency.
library;

import 'constants.dart';
import 'types.dart';

class FormThresholds {
  const FormThresholds({
    required this.swingThreshold,
    required this.torsoLeanThresholdDeg,
    required this.backLeanThresholdDeg,
    required this.shrugThreshold,
    required this.driftThreshold,
    required this.elbowRiseThreshold,
  });

  final double swingThreshold;
  final double torsoLeanThresholdDeg;
  final double backLeanThresholdDeg;
  final double shrugThreshold;
  final double driftThreshold;
  final double elbowRiseThreshold;

  /// Medium sensitivity — mirrors the hard-coded constants exactly so existing
  /// call sites that pass no thresholds are bit-for-bit identical to pre-sensitivity.
  static const FormThresholds medium = FormThresholds(
    swingThreshold: kSwingThreshold,
    torsoLeanThresholdDeg: kTorsoLeanThresholdDeg,
    backLeanThresholdDeg: kBackLeanThresholdDeg,
    shrugThreshold: kShrugThreshold,
    driftThreshold: kDriftThreshold,
    elbowRiseThreshold: kElbowRiseThreshold,
  );

  factory FormThresholds.forSensitivity(CurlSensitivity s) {
    final m = switch (s) {
      CurlSensitivity.high => 0.75,
      CurlSensitivity.medium => 1.0,
    };
    return FormThresholds(
      swingThreshold: kSwingThreshold * m,
      torsoLeanThresholdDeg: kTorsoLeanThresholdDeg * m,
      backLeanThresholdDeg: kBackLeanThresholdDeg * m,
      shrugThreshold: kShrugThreshold * m,
      driftThreshold: kDriftThreshold * m,
      elbowRiseThreshold: kElbowRiseThreshold * m,
    );
  }
}
