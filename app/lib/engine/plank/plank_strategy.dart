import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'plank_form_analyzer.dart';

/// Timed-hold strategy for a forearm plank.
///
/// The shared counter is rep-oriented, so this strategy emits one committed
/// unit for each clean hold second. Bad-pose seconds still produce quality
/// samples, but do not advance the hold countdown.
class PlankStrategy extends ExerciseStrategy {
  PlankStrategy() : _form = PlankFormAnalyzer();

  final PlankFormAnalyzer _form;
  DateTime? _lastSecondBoundary;
  DateTime? _lastBadSampleAt;
  DateTime? _invalidSince;
  int _sampleIndex = 0;
  PlankSecondSample? _lastSecondSample;

  @override
  ExerciseType get exercise => ExerciseType.plank;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(ExerciseType.plank).landmarkIndices;

  PlankSecondSample? get lastSecondSample => _lastSecondSample;

  @override
  double? computePrimaryAngle(PoseResult pose) {
    final left = _sideElbowAngle(pose, isLeft: true);
    final right = _sideElbowAngle(pose, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right!.angleDeg;
    if (right == null) return left.angleDeg;
    return left.confidenceSum >= right.confidenceSum
        ? left.angleDeg
        : right.angleDeg;
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final errors = _form.evaluate(input.pose, now: input.now);
    final rawValid = errors.isEmpty;
    var countable = rawValid;
    if (rawValid) {
      _invalidSince = null;
    } else {
      _invalidSince ??= input.now;
      countable = _lastSecondBoundary != null &&
          input.now.difference(_invalidSince!) <= kPlankInvalidGrace;
    }
    final quality = _form.lastQuality ?? 0.0;
    var cleanSecond = false;

    if (countable) {
      if (rawValid) _lastBadSampleAt = null;
      _lastSecondBoundary ??= input.now;
      while (input.now.difference(_lastSecondBoundary!).inSeconds >= 1) {
        _lastSecondBoundary = _lastSecondBoundary!.add(
          const Duration(seconds: 1),
        );
        _recordSecondSample(quality: quality, valid: rawValid);
        cleanSecond = true;
      }
    } else {
      _lastSecondBoundary = input.now;
      if (_lastBadSampleAt == null ||
          input.now.difference(_lastBadSampleAt!).inSeconds >= 1) {
        _lastBadSampleAt = input.now;
        _recordSecondSample(quality: quality, valid: false);
      }
    }

    return StrategyFrameOutput(
      nextState: RepState.idle,
      repCommitted: cleanSecond,
      formErrors: errors,
    );
  }

  @override
  void onNextSet() => reset();

  @override
  void onReset() => reset();

  void reset() {
    _lastSecondBoundary = null;
    _lastBadSampleAt = null;
    _invalidSince = null;
    _sampleIndex = 0;
    _lastSecondSample = null;
    _form.reset();
  }

  void _recordSecondSample({required double quality, required bool valid}) {
    _sampleIndex++;
    _lastSecondSample = PlankSecondSample(
      index: _sampleIndex,
      quality: quality,
      valid: valid,
    );
  }

  _ElbowAngleCandidate? _sideElbowAngle(
    PoseResult pose, {
    required bool isLeft,
  }) {
    final shoulder = pose.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final elbow = pose.landmark(
      isLeft ? LM.leftElbow : LM.rightElbow,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final wrist = pose.landmark(
      isLeft ? LM.leftWrist : LM.rightWrist,
      minConfidence: kPlankMinLandmarkConfidence,
    );
    final elbowAngle = angleDeg(shoulder, elbow, wrist);
    if (shoulder == null ||
        elbow == null ||
        wrist == null ||
        elbowAngle == null) {
      return null;
    }
    return _ElbowAngleCandidate(
      angleDeg: elbowAngle,
      confidenceSum: shoulder.confidence + elbow.confidence + wrist.confidence,
    );
  }
}

class _ElbowAngleCandidate {
  const _ElbowAngleCandidate({
    required this.angleDeg,
    required this.confidenceSum,
  });

  final double angleDeg;
  final double confidenceSum;
}
