import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'push_up_form_analyzer.dart';

/// Push-up FSM encapsulated as a strategy.
///
/// No session-scoped state — all tracking resets per rep.
class PushUpStrategy extends ExerciseStrategy {
  PushUpStrategy();

  final PushUpFormAnalyzer _form = PushUpFormAnalyzer();

  @override
  ExerciseType get exercise => ExerciseType.pushUp;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(ExerciseType.pushUp).landmarkIndices;

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

  double? get lastRepQuality => _form.lastRepQuality;

  double? get lastBodyLineDeviationDeg => _form.lastBodyLineDeviationDeg;

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;

    if (input.state == RepState.descending ||
        input.state == RepState.bottom ||
        input.state == RepState.ascending) {
      _form.trackAngle(smoothed);
    }

    var nextState = input.state;
    var repCommitted = false;
    var errors = <FormError>[];

    switch (input.state) {
      case RepState.idle:
        if (smoothed < kPushUpStartAngle) {
          nextState = RepState.descending;
          _form.onRepStart(pose);
        }
      case RepState.descending:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed < kPushUpBottomAngle) {
          nextState = RepState.bottom;
        } else if (smoothed > kPushUpStartAngle) {
          nextState = RepState.idle;
        }
      case RepState.bottom:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed > kPushUpBottomAngle) {
          nextState = RepState.ascending;
        }
      case RepState.ascending:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed >= kPushUpEndAngle) {
          final completionErrors = _form.consumeCompletionErrors();
          errors = [...errors, ...completionErrors];
          repCommitted = true;
          nextState = RepState.idle;
        }
      default:
        break;
    }

    return StrategyFrameOutput(
      nextState: nextState,
      repCommitted: repCommitted,
      formErrors: errors,
    );
  }

  @override
  void onNextSet() => _form.reset();

  @override
  void onReset() => _form.reset();

  _ElbowAngleCandidate? _sideElbowAngle(
    PoseResult pose, {
    required bool isLeft,
  }) {
    final shoulder = pose.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final elbow = pose.landmark(
      isLeft ? LM.leftElbow : LM.rightElbow,
      minConfidence: kMinLandmarkConfidence,
    );
    final wrist = pose.landmark(
      isLeft ? LM.leftWrist : LM.rightWrist,
      minConfidence: kMinLandmarkConfidence,
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
