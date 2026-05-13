import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';
import 'push_up_rom_profile.dart';

/// Form analyzer for side-view push-ups.
///
/// Frame-level errors:
///   - Hip sag / pike: |180 - shoulder-hip-ankle angle| > kHipSagDeviation.
///     The rep still counts, but the committed quality score is penalized.
///
/// Rep-boundary error:
///   - Partial ROM: rep completed without elbow angle reaching kPushUpBottomAngle.
class PushUpFormAnalyzer extends FormAnalyzerBase {
  PushUpFormAnalyzer({
    PushUpRomThresholds thresholds = PushUpRomThresholds.defaults,
  }) : _thresholds = thresholds;

  PushUpRomThresholds _thresholds;
  double? _minElbowAngle;
  double? _maxElbowAngleThisRep;
  double? _maxBodyLineDeviationDeg;
  double? _lastRepQuality;
  double? _lastBodyLineDeviationDeg;
  double? _lastRepMinElbowAngle;
  double? _lastRepMaxElbowAngle;

  /// Quality score for the most recently committed rep. Null until first
  /// commit. 1.0 is clean; deductions are applied for body-line loss and
  /// short ROM.
  double? get lastRepQuality => _lastRepQuality;

  /// Largest shoulder-hip-ankle deviation observed on the most recent rep.
  double? get lastBodyLineDeviationDeg => _lastBodyLineDeviationDeg;

  /// Lowest elbow angle observed during the most recently committed rep
  /// (i.e. the rep's bottom extension). Null until the first commit.
  /// Feeds the `pushup.rep` telemetry line read by the offline ROM-derivation
  /// script.
  double? get lastRepMinElbowAngle => _lastRepMinElbowAngle;

  /// Highest elbow angle observed during the most recently committed rep
  /// (i.e. the rep's top extension). Null until the first commit. Companion
  /// to [lastRepMinElbowAngle] — together they define the rep's ROM tuple.
  double? get lastRepMaxElbowAngle => _lastRepMaxElbowAngle;

  /// True when the user moved far enough down to treat the attempt as a
  /// shallow push-up if they return to full extension before reaching bottom.
  bool get hasShallowRepAttempt =>
      _minElbowAngle != null &&
      _minElbowAngle! <= _thresholds.shallowRepMaxAngle;

  void updateThresholds(PushUpRomThresholds thresholds) {
    _thresholds = thresholds;
  }

  @override
  void onRepStart(PoseResult startSnapshot) {
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
  }

  /// Call every frame during an in-progress rep to track the lowest point.
  void trackAngle(double elbowAngle) {
    if (_minElbowAngle == null || elbowAngle < _minElbowAngle!) {
      _minElbowAngle = elbowAngle;
    }
  }

  /// Per-frame max-elbow tracker. Mirrors [trackAngle] but captures the
  /// rep's top extension instead of its bottom. Called alongside
  /// [trackAngle] from `PushUpStrategy.tick()` whenever the FSM is in an
  /// active rep state. Separate accumulator from `_minElbowAngle` so the
  /// existing min-tracking contract is unchanged.
  void trackMaxElbow(double elbowAngle) {
    if (_maxElbowAngleThisRep == null || elbowAngle > _maxElbowAngleThisRep!) {
      _maxElbowAngleThisRep = elbowAngle;
    }
  }

  /// Frame-level evaluation. Counts the rep regardless of body-line quality;
  /// the error and quality score carry the fault.
  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];
    final deviation = _bodyLineDeviationDeg(current);

    if (deviation != null) {
      if (_maxBodyLineDeviationDeg == null ||
          deviation > _maxBodyLineDeviationDeg!) {
        _maxBodyLineDeviationDeg = deviation;
      }
      if (deviation > kHipSagDeviation) {
        errors.add(FormError.hipSag);
      }
    }

    return errors;
  }

  /// Rep-boundary evaluation. Computes the per-rep quality score, snapshots
  /// it for the strategy to read, then clears the in-progress extrema.
  @override
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];
    final shortRom =
        _minElbowAngle != null && _minElbowAngle! >= _thresholds.bottomAngle;
    if (shortRom) {
      errors.add(FormError.pushUpShortRom);
    }

    _lastRepQuality = _computeQualityScore(shortRom: shortRom);
    _lastBodyLineDeviationDeg = _maxBodyLineDeviationDeg;
    _lastRepMinElbowAngle = _minElbowAngle;
    _lastRepMaxElbowAngle = _maxElbowAngleThisRep;
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
    return errors;
  }

  @override
  void reset() {
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
    _lastRepQuality = null;
    _lastBodyLineDeviationDeg = null;
    _lastRepMinElbowAngle = null;
    _lastRepMaxElbowAngle = null;
  }

  double _computeQualityScore({required bool shortRom}) {
    var score = 1.0;
    final deviation = _maxBodyLineDeviationDeg;
    if (deviation != null && deviation > kHipSagDeviation) {
      final severity = ((deviation - kHipSagDeviation) / kHipSagDeviation)
          .clamp(0.0, 1.0);
      score -= kQualityPushUpHipSagMaxDeduction * severity;
    }
    if (shortRom) {
      score -= kQualityPushUpShortRomDeduction;
    }
    return score.clamp(0.0, 1.0);
  }

  /// Side-view body-line deviation. Picks the visible side with stronger
  /// shoulder+hip+ankle confidence, then measures the hip angle. A straight
  /// body is near 180 degrees; both sagging and piking increase deviation.
  double? _bodyLineDeviationDeg(PoseResult p) {
    final left = _sideBodyLineDeviation(p, isLeft: true);
    final right = _sideBodyLineDeviation(p, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right!.deviationDeg;
    if (right == null) return left.deviationDeg;
    return left.confidenceSum >= right.confidenceSum
        ? left.deviationDeg
        : right.deviationDeg;
  }

  _BodyLineCandidate? _sideBodyLineDeviation(
    PoseResult p, {
    required bool isLeft,
  }) {
    final shoulder = p.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    final hipAngle = angleDeg(shoulder, hip, ankle);
    if (shoulder == null || hip == null || ankle == null || hipAngle == null) {
      return null;
    }
    return _BodyLineCandidate(
      deviationDeg: (180.0 - hipAngle).abs(),
      confidenceSum: shoulder.confidence + hip.confidence + ankle.confidence,
    );
  }
}

class _BodyLineCandidate {
  const _BodyLineCandidate({
    required this.deviationDeg,
    required this.confidenceSum,
  });

  final double deviationDeg;
  final double confidenceSum;
}
