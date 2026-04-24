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
    final leftAngle = angleDeg(
      pose.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftElbow, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftWrist, minConfidence: kMinLandmarkConfidence),
    );
    final rightAngle = angleDeg(
      pose.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightElbow, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightWrist, minConfidence: kMinLandmarkConfidence),
    );
    if (leftAngle != null && rightAngle != null) {
      return (leftAngle + rightAngle) / 2.0;
    }
    return leftAngle ?? rightAngle;
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;

    if (input.state == RepState.descending || input.state == RepState.bottom) {
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
        if (smoothed < kPushUpBottomAngle) {
          nextState = RepState.bottom;
        } else if (smoothed > kPushUpStartAngle) {
          nextState = RepState.idle;
        }
      case RepState.bottom:
        errors = _form.evaluate(pose);
        if (smoothed > kPushUpBottomAngle) {
          nextState = RepState.ascending;
        }
      case RepState.ascending:
        errors = _form.evaluate(pose);
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
}
