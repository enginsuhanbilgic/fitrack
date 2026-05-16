import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'push_up_form_analyzer.dart';
import 'push_up_rom_profile.dart';

/// Synchronous push-up threshold resolver. Called once per rep at the
/// IDLE → DESCENDING transition. Implementations consult (in order):
/// calibrated profile (Tier 1) → in-session auto-cal (Tier 2) →
/// `PushUpRomThresholds.defaults` (Tier 3, sensitivity-modified).
///
/// `repIndexInSet` is included to match the curl/squat provider
/// signatures even though push-up has no warm-up concept today — the
/// extra parameter is a tiny price for cross-exercise call-site
/// uniformity, and future warm-up logic (e.g., a "first rep counts at
/// a looser threshold" rule) lands without an API churn.
///
/// MUST be synchronous — the FSM hot path cannot await I/O.
typedef PushUpRomThresholdsProvider =
    PushUpRomThresholds Function(int repIndexInSet);

/// Push-up FSM encapsulated as a strategy.
///
/// No session-scoped state — all tracking resets per rep.
class PushUpStrategy extends ExerciseStrategy {
  PushUpStrategy({
    PushUpRomThresholds thresholds = PushUpRomThresholds.defaults,
    PushUpRomThresholdsProvider? thresholdsProvider,
    List<Duration> historicalConcentricDurations = const [],
  }) : _thresholds = thresholds,
       _thresholdsProvider = thresholdsProvider,
       _form = PushUpFormAnalyzer(
         thresholds: thresholds,
         historicalConcentricDurations: historicalConcentricDurations,
       );

  PushUpRomThresholds _thresholds;
  final PushUpRomThresholdsProvider? _thresholdsProvider;
  final PushUpFormAnalyzer _form;

  /// Per-rep index, advanced on each rep commit. Passed to the
  /// `_thresholdsProvider` at IDLE → DESCENDING so the resolver can
  /// implement warm-up logic in the future. Starts at 0 and resets on
  /// `onNextSet()` (mirrors curl/squat's per-set rep indexing).
  int _repIndexInSet = 0;

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

  /// Ascent (concentric/press) duration of the most recently committed
  /// rep. Null on shallow reps with no measured ascent. Pass-through to
  /// the analyzer — consumed by the host's `_handlePushUpRepCommit` for
  /// `concentric_ms` persistence + the cross-session fatigue baseline.
  Duration? get lastConcentricDuration => _form.lastConcentricDuration;

  double? get lastBodyLineDeviationDeg => _form.lastBodyLineDeviationDeg;

  /// Most recently committed rep's bottom-of-rep elbow extension (degrees).
  /// Null until the first rep commits. Pass-through to the form analyzer —
  /// the strategy doesn't accumulate its own ROM state. Consumed by the
  /// host's `_handlePushUpRepCommit` to emit the `pushup.rep` telemetry line.
  double? get lastRepMinElbowAngle => _form.lastRepMinElbowAngle;

  /// Most recently committed rep's top-of-rep elbow extension (degrees).
  /// Null until the first rep commits. Pass-through getter — see
  /// [lastRepMinElbowAngle] for the lifecycle contract.
  double? get lastRepMaxElbowAngle => _form.lastRepMaxElbowAngle;

  void updateThresholds(PushUpRomThresholds thresholds) {
    _thresholds = thresholds;
    _form.updateThresholds(thresholds);
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;

    if (input.state == RepState.descending ||
        input.state == RepState.bottom ||
        input.state == RepState.ascending) {
      _form.trackAngle(smoothed);
      _form.trackMaxElbow(smoothed);
    }

    var nextState = input.state;
    var repCommitted = false;
    var errors = <FormError>[];

    switch (input.state) {
      case RepState.idle:
        if (smoothed < _thresholds.startAngle) {
          // Resolve thresholds at the rep boundary. Mirrors the curl /
          // squat per-rep resolution pattern: the host's three-tier
          // resolver runs once and the result is locked for the rest of
          // this rep — the FSM never re-resolves mid-rep
          // (threshold-lock invariant). When no provider is wired, the
          // construction-time tuple stays in force.
          final provider = _thresholdsProvider;
          if (provider != null) {
            final resolved = provider(_repIndexInSet);
            _thresholds = resolved;
            _form.updateThresholds(resolved);
          }
          nextState = RepState.descending;
          _form.onRepStart(pose);
          // Eccentric (descent) phase clock starts here.
          _form.onDescentStart(input.now);
          _form.trackAngle(smoothed);
          _form.trackMaxElbow(smoothed);
        }
      case RepState.descending:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed < _thresholds.bottomAngle) {
          nextState = RepState.bottom;
        } else if (smoothed >= _thresholds.endAngle) {
          if (_form.hasShallowRepAttempt) {
            // Shallow rep: reversed before BOTTOM, so there is no
            // concentric (ascent) phase. We deliberately do NOT call
            // onAscentStart/onAscentEnd — `lastConcentricDuration` stays
            // null and the tempo/fatigue signals correctly skip this rep
            // (there was no controlled press to grade).
            final completionErrors = _form.consumeCompletionErrors();
            errors = [...errors, ...completionErrors];
            repCommitted = true;
            _repIndexInSet++;
          }
          nextState = RepState.idle;
        }
      case RepState.bottom:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed > _thresholds.bottomAngle) {
          // Concentric (ascent) phase clock starts; closes the eccentric
          // timer inside the analyzer.
          _form.onAscentStart(input.now);
          nextState = RepState.ascending;
        }
      case RepState.ascending:
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed >= _thresholds.endAngle) {
          // Close the concentric timer BEFORE consuming completion errors
          // so the tempo/fatigue signals see this rep's final ascent
          // duration.
          _form.onAscentEnd(input.now);
          final completionErrors = _form.consumeCompletionErrors();
          errors = [...errors, ...completionErrors];
          repCommitted = true;
          _repIndexInSet++;
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
  void onNextSet() {
    _repIndexInSet = 0;
    _form.reset();
  }

  @override
  void onReset() {
    _repIndexInSet = 0;
    _form.reset();
  }

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
