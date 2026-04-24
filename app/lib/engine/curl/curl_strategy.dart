import '../../core/constants.dart';
import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'curl_form_analyzer.dart';
import 'curl_form_analyzer_extras.dart';
import 'curl_view_detector.dart';

/// Resolves the RomThresholds to apply for the next curl rep.
///
/// Called once per rep at IDLE→CONCENTRIC. Implementations typically look up
/// `(side, view)` in a profile, fall back to an in-set auto-calibrator, and
/// finally to globals. The provider must be **synchronous** — there is no
/// time to await I/O in the FSM hot path.
typedef RomThresholdsProvider =
    RomThresholds Function(
      ProfileSide side,
      CurlCameraView view,
      int repIndexInSet,
    );

/// Invoked after each successfully-counted curl rep, with the per-rep
/// extremes and the (side, view) attribution. Caller is responsible for
/// updating the persistent profile (and dropping samples whose view is
/// unknown — the strategy already filters those upstream).
typedef CurlRepCommitCallback =
    void Function({
      required ProfileSide side,
      required CurlCameraView view,
      required double minAngle,
      required double maxAngle,
    });

/// Biceps-curl FSM encapsulated as a strategy.
///
/// Owns:
///   - [CurlFormAnalyzer] (quality, tempo, asymmetry, fatigue).
///   - [CurlViewDetector] + active-phase re-detection hysteresis.
///   - Per-rep extremes, locked thresholds, and the rep-commit callback.
///
/// Does NOT own:
///   - `kStateDebounce` / `kStuckStateLimit` — those gate `RepCounter.update`
///     before `tick` runs (invariant 1 & 2).
class CurlStrategy extends ExerciseStrategy {
  CurlStrategy({
    this.side = ExerciseSide.both,
    RomThresholdsProvider? thresholdsProvider,
    CurlRepCommitCallback? onRepCommit,
  }) : _thresholdsProvider = thresholdsProvider ?? _defaultGlobalProvider,
       _onRepCommit = onRepCommit;

  final ExerciseSide side;
  final RomThresholdsProvider _thresholdsProvider;
  final CurlRepCommitCallback? _onRepCommit;

  final CurlFormAnalyzer _form = CurlFormAnalyzer();
  final CurlViewDetector _viewDetector = CurlViewDetector();

  CurlCameraView _lockedView = CurlCameraView.unknown;
  CurlCameraView _pendingView = CurlCameraView.unknown;
  int _pendingViewStreak = 0;

  bool _reachedPeak = false;
  double? _minAngleThisRep;
  double? _maxAngleAtStart;

  // Sentinel: overwritten on the first IDLE→CONCENTRIC tick (line 160) before
  // any state that reads `_activeThresholds` (CONCENTRIC/PEAK/ECCENTRIC) can
  // execute. Passing a real view here would still resolve to `sideLeft`
  // because `_lockedView == unknown` at construction.
  RomThresholds _activeThresholds = RomThresholds.global();

  static RomThresholds _defaultGlobalProvider(
    ProfileSide _,
    CurlCameraView view,
    int _,
  ) => RomThresholds.global(view);

  @override
  ExerciseType get exercise => ExerciseType.bicepsCurl;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  /// Intersection view — used by hosts that need the curl-specific extras
  /// (quality getters, fatigue flag) without a downcast.
  CurlFormAnalyzerExtras get formExtras => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(ExerciseType.bicepsCurl).landmarkIndices;

  /// Read by the RepCounter snapshot so the UI can surface the locked view.
  CurlCameraView get lockedView => _lockedView;

  @override
  double? computePrimaryAngle(PoseResult pose) {
    // Lower confidence gate than shared default — allows tracking when the
    // user turns slightly and landmarks get noisier.
    const curlConf = 0.2;
    final leftAngle = angleDeg(
      pose.landmark(LM.leftShoulder, minConfidence: curlConf),
      pose.landmark(LM.leftElbow, minConfidence: curlConf),
      pose.landmark(LM.leftWrist, minConfidence: curlConf),
    );
    final rightAngle = angleDeg(
      pose.landmark(LM.rightShoulder, minConfidence: curlConf),
      pose.landmark(LM.rightElbow, minConfidence: curlConf),
      pose.landmark(LM.rightWrist, minConfidence: curlConf),
    );
    if (leftAngle != null && rightAngle != null) {
      return (leftAngle + rightAngle) / 2.0;
    }
    return leftAngle ?? rightAngle;
  }

  @override
  CurlCameraView updateSetupView(PoseResult pose) {
    final view = _viewDetector.update(pose);
    if (_viewDetector.isLocked && _lockedView == CurlCameraView.unknown) {
      _lockedView = view;
      _form.setView(_lockedView);
    }
    return _lockedView;
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;

    // Track per-rep min during active phases — committed as a sample when
    // the rep counts.
    if (input.state == RepState.concentric || input.state == RepState.peak) {
      if (_minAngleThisRep == null || smoothed < _minAngleThisRep!) {
        _minAngleThisRep = smoothed;
      }
    }

    // Continuous view re-detection once a view is locked. Only applies a
    // switch when FSM is idle — never mid-rep (invariant 10).
    if (_lockedView != CurlCameraView.unknown) {
      _updateActiveViewDetection(pose, input.state);
    }

    var nextState = input.state;
    var repCommitted = false;
    var errors = <FormError>[];

    switch (input.state) {
      case RepState.idle:
        // Resolve thresholds NOW. Threshold-source promotion happens only
        // here (invariant 4) — never mid-rep.
        final resolved = _thresholdsProvider(
          _profileSideForRep(),
          _lockedView,
          input.repIndexInSet,
        );
        if (smoothed < resolved.startAngle) {
          _activeThresholds = resolved;
          nextState = RepState.concentric;
          _reachedPeak = false;
          _maxAngleAtStart = smoothed;
          _minAngleThisRep = smoothed;
          _form.setActiveThresholds(resolved);
          _form.onRepStart(pose);
        }
      case RepState.concentric:
        errors = _form.evaluate(pose);
        if (smoothed <= _activeThresholds.peakAngle) {
          nextState = RepState.peak;
          _reachedPeak = true;
          _form.onPeakReached();
        } else if (smoothed > _activeThresholds.startAngle) {
          // Abandoned rep — never reached peak.
          if (!_reachedPeak) {
            _form.onAbortedRep(
              maxAngleAtStart: _maxAngleAtStart ?? smoothed,
              minAngleReached: _minAngleThisRep ?? smoothed,
            );
          }
          errors = [...errors, ..._form.consumeCompletionErrors()];
          nextState = RepState.idle;
          _resetPerRepState();
        }
      case RepState.peak:
        if (smoothed > _activeThresholds.peakExitAngle) {
          nextState = RepState.eccentric;
          _form.onEccentricStart();
        }
      case RepState.eccentric:
        errors = _form.evaluate(pose);
        if (smoothed >= _activeThresholds.endAngle) {
          // Commit the rep.
          final leftBilateral = _computeBilateralAngle(pose, left: true);
          final rightBilateral = _computeBilateralAngle(pose, left: false);
          _form.recordBilateralAngles(leftBilateral, rightBilateral);
          errors = [...errors, ..._form.consumeCompletionErrors()];
          _form.onRepEnd();
          _commitRepSamples(leftBilateral, rightBilateral);
          repCommitted = true;
          nextState = RepState.idle;
          _resetPerRepState();
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
    _reachedPeak = false;
    _minAngleThisRep = null;
    _maxAngleAtStart = null;
    _activeThresholds = RomThresholds.global();
    _viewDetector.reset();
    _lockedView = CurlCameraView.unknown;
    _pendingView = CurlCameraView.unknown;
    _pendingViewStreak = 0;
    _form.reset();
  }

  @override
  void onReset() {
    _reachedPeak = false;
    _minAngleThisRep = null;
    _maxAngleAtStart = null;
    _activeThresholds = RomThresholds.global();
    _viewDetector.reset();
    _lockedView = CurlCameraView.unknown;
    _pendingView = CurlCameraView.unknown;
    _pendingViewStreak = 0;
    _form.reset();
  }

  // ── Internals ─────────────────────────────────────────────────────

  ProfileSide _profileSideForRep() => switch (side) {
    ExerciseSide.right => ProfileSide.right,
    _ => ProfileSide.left,
  };

  /// Apply any deferred view switch post-commit. Mirrors the original
  /// `_resetToIdle` behavior in the old `RepCounter`.
  void _maybeApplyDeferredViewSwitch() {
    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        _pendingView != CurlCameraView.unknown) {
      _lockedView = _pendingView;
      _form.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  void _resetPerRepState() {
    _reachedPeak = false;
    _minAngleThisRep = null;
    _maxAngleAtStart = null;
    _maybeApplyDeferredViewSwitch();
  }

  /// Runs every frame once a view is locked. Pending view switches apply
  /// ONLY when the FSM is idle (never mid-rep, invariant 10).
  void _updateActiveViewDetection(PoseResult pose, RepState state) {
    final candidate = _viewDetector.classifyFrame(
      pose,
      currentLocked: _lockedView,
    );

    if (candidate == CurlCameraView.unknown || candidate == _lockedView) {
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
      return;
    }

    if (candidate == _pendingView) {
      _pendingViewStreak++;
    } else {
      _pendingView = candidate;
      _pendingViewStreak = 1;
    }

    if (_pendingViewStreak >= kViewRedetectHysteresisFrames &&
        state == RepState.idle) {
      _lockedView = _pendingView;
      _form.setView(_lockedView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  double? _computeBilateralAngle(PoseResult r, {required bool left}) {
    if (left) {
      return angleDeg(
        r.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
        r.landmark(LM.leftElbow, minConfidence: kMinLandmarkConfidence),
        r.landmark(LM.leftWrist, minConfidence: kMinLandmarkConfidence),
      );
    }
    return angleDeg(
      r.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      r.landmark(LM.rightElbow, minConfidence: kMinLandmarkConfidence),
      r.landmark(LM.rightWrist, minConfidence: kMinLandmarkConfidence),
    );
  }

  /// Front-view attribution rule: commit to *both* `(left, right)` buckets
  /// only when both arms reached PEAK with bilateral delta below
  /// [kAsymmetryAngleDelta]. Otherwise commit only the working side.
  /// View-unknown reps never fire the commit (invariant 9).
  void _commitRepSamples(double? leftBilateral, double? rightBilateral) {
    final commit = _onRepCommit;
    if (commit == null) return;
    if (_lockedView == CurlCameraView.unknown) return;
    final minAngle = _minAngleThisRep;
    final maxAngle = _maxAngleAtStart;
    if (minAngle == null || maxAngle == null) return;

    final isFrontView = _lockedView == CurlCameraView.front;
    final symmetric =
        isFrontView &&
        leftBilateral != null &&
        rightBilateral != null &&
        (leftBilateral - rightBilateral).abs() < kAsymmetryAngleDelta;

    if (symmetric) {
      commit(
        side: ProfileSide.left,
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
      );
      commit(
        side: ProfileSide.right,
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
      );
    } else {
      commit(
        side: _profileSideForRep(),
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
      );
    }
  }
}
