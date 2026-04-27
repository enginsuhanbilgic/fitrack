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
import 'curl_side_form_analyzer.dart';
import 'curl_view_detector.dart';
import 'dtw_scorer.dart';

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

/// Invoked when the runtime view detector commits a flip from one locked
/// view to another (e.g. `sideRight → sideLeft` after the user rotates
/// 180° mid-session). Fires AT MOST ONCE per FSM idle transition, never
/// mid-rep (preserves invariant 10), and never on the initial
/// `unknown → locked` transition (that's a "first lock", not a flip).
///
/// When `to == CurlCameraView.front` and `kCurlFrontViewEnabled == false`,
/// the callback still fires (so the host can surface a "front view not
/// supported" advisory) but the strategy does NOT switch the analyzer to
/// the dormant front code path — `_lockedView` updates, the side analyzer
/// keeps processing.
typedef CurlViewFlipCallback =
    void Function(CurlCameraView from, CurlCameraView to);

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

      /// Most recent rep's concentric duration as measured by
      /// [CurlFormAnalyzer]. Nullable because a rep can commit before the
      /// analyzer's `onPeakReached` fires (partial reps, edge cases); hosts
      /// should treat null as "no data" and skip persistence rather than
      /// inferring a duration. Added in WP5.4.
      required Duration? concentricDuration,

      /// Angle measured at CONCENTRIC → PEAK promotion (the angle when
      /// the FSM first declared peak reached). Distinct from `minAngle`,
      /// which is the running min over the entire rep — `minAtPeak` is
      /// the first frame to clear the peak gate, BEFORE any post-peak
      /// drift can pull `minAngle` lower from pose-estimator noise. Lets
      /// diagnostics distinguish "user held a real peak" (minAtPeak ≈
      /// minAngle) from "FSM crossed gate then noise spiked lower"
      /// (minAtPeak ~70°, minAngle ~3° — a known 2D-pose artifact at
      /// peak elbow flexion when the wrist projects near the shoulder).
      /// Optional / nullable so existing callers compile unchanged.
      double? minAtPeak,
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

    /// Fires when the runtime view detector commits a view flip
    /// (`sideRight → sideLeft`, `sideLeft → front`, etc.). See
    /// [CurlViewFlipCallback] for the full contract.
    CurlViewFlipCallback? onViewFlipped,

    /// 30-day historical concentric durations for the analyzer's fatigue
    /// baseline (WP5.4). Empty list → backward-compat pre-WP5.4 behavior.
    List<Duration> historicalConcentricDurations = const [],

    /// Reference angle series for DTW form scoring (T5.3). Null = disabled.
    List<double>? referenceRepAngleSeries,
    bool enableDtwScoring = false,

    /// The exercise variant this strategy represents. Determines what
    /// [exercise] returns and which thresholds are appropriate.
    ExerciseType exerciseType = ExerciseType.bicepsCurlFront,

    /// Pre-declared camera view. When non-unknown the view detector still
    /// runs (for framing confirmation) but [_lockedView] is immutable —
    /// the detector result never overrides the declared view.
    CurlCameraView initialView = CurlCameraView.unknown,
  }) : _exerciseType = exerciseType,
       _initialView = initialView,
       _thresholdsProvider = thresholdsProvider ?? _defaultGlobalProvider,
       _onRepCommit = onRepCommit,
       _onViewFlipped = onViewFlipped,
       _form = _selectAnalyzer(
         initialView: initialView,
         historicalConcentricDurations: historicalConcentricDurations,
         referenceRepAngleSeries: referenceRepAngleSeries,
         enableDtwScoring: enableDtwScoring,
       ) {
    if (initialView != CurlCameraView.unknown) {
      _lockedView = initialView;
      _form.setView(initialView);
    }
  }

  final ExerciseType _exerciseType;
  final CurlCameraView _initialView;
  final ExerciseSide side;
  final RomThresholdsProvider _thresholdsProvider;
  final CurlRepCommitCallback? _onRepCommit;
  final CurlViewFlipCallback? _onViewFlipped;

  /// Form analyzer for the current view. Polymorphic: either
  /// `CurlFormAnalyzer` (front, frozen battle-tested code path) or
  /// `CurlSideFormAnalyzer` (side, isolated for independent iteration).
  /// Typed as the [CurlAnalyzer] umbrella so all strategy call sites
  /// compile against base + extras without downcasts.
  final CurlAnalyzer _form;
  final CurlViewDetector _viewDetector = CurlViewDetector();

  CurlCameraView _lockedView = CurlCameraView.unknown;
  CurlCameraView _pendingView = CurlCameraView.unknown;
  int _pendingViewStreak = 0;

  bool _reachedPeak = false;
  double? _minAngleThisRep;
  double? _maxAngleAtStart;

  /// Angle observed at the moment the FSM first transitions
  /// CONCENTRIC → PEAK. Captured exactly once per rep (the first frame to
  /// clear `peakAngle`). Distinct from `_minAngleThisRep` which keeps
  /// dropping if pose noise pushes the angle lower after peak. Cleared in
  /// `_resetPerRepState` and `onNextSet/onReset`.
  double? _minAngleAtPeak;

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
  ExerciseType get exercise => _exerciseType;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  /// Intersection view — used by hosts that need the curl-specific extras
  /// (quality getters, fatigue flag) without a downcast.
  CurlFormAnalyzerExtras get formExtras => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(_exerciseType).landmarkIndices;

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
        // Feed IDLE frames to the analyzer so view-aware detectors (like
        // sagittal sway) can collect baseline neutral-pose samples.
        errors = _form.evaluate(pose, now: input.now);

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
        errors = _form.evaluate(pose, now: input.now);
        if (smoothed <= _activeThresholds.peakAngle) {
          nextState = RepState.peak;
          _reachedPeak = true;
          // Capture the angle at the FIRST frame that cleared the peak
          // gate. Don't overwrite on subsequent CONCENTRIC frames (there
          // shouldn't be any — the state changes here — but defensive).
          _minAngleAtPeak ??= smoothed;
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
        errors = _form.evaluate(pose, now: input.now);
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
    _minAngleAtPeak = null;
    _activeThresholds = RomThresholds.global();
    _viewDetector.reset();
    // Sticky view across set boundaries: a user's body orientation persists
    // between sets, so reverting to the picker's _initialView would force
    // the runtime detector to re-acquire any flip every set (~10 idle
    // frames of hysteresis each time). Only fall back to _initialView when
    // no view has ever locked.
    _lockedView = _lockedView != CurlCameraView.unknown
        ? _lockedView
        : _initialView;
    _pendingView = CurlCameraView.unknown;
    _pendingViewStreak = 0;
    _form.reset();
    if (_lockedView != CurlCameraView.unknown) _form.setView(_lockedView);
  }

  @override
  void onReset() {
    _reachedPeak = false;
    _minAngleThisRep = null;
    _maxAngleAtStart = null;
    _minAngleAtPeak = null;
    _activeThresholds = RomThresholds.global();
    _viewDetector.reset();
    // See onNextSet for sticky-view rationale.
    _lockedView = _lockedView != CurlCameraView.unknown
        ? _lockedView
        : _initialView;
    _pendingView = CurlCameraView.unknown;
    _pendingViewStreak = 0;
    _form.reset();
    if (_lockedView != CurlCameraView.unknown) _form.setView(_lockedView);
  }

  /// Score a completed rep's angle trace against the reference. Delegates to
  /// [CurlFormAnalyzer.scoreRep]. Returns null when scoring is disabled.
  DtwScore? scoreRep(List<double> candidate) => _form.scoreRep(candidate);

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
      final from = _lockedView;
      _applyViewFlip(from, _pendingView);
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
    }
  }

  /// Single chokepoint for runtime view flips. Mutates [_lockedView],
  /// optionally switches the analyzer (gated by [kCurlFrontViewEnabled] when
  /// `to == front`), then fires [_onViewFlipped]. Never invoked for the
  /// initial `unknown → locked` transition — that path runs through
  /// [updateSetupView] / the constructor and intentionally does NOT fire
  /// the callback (per the [CurlViewFlipCallback] contract).
  void _applyViewFlip(CurlCameraView from, CurlCameraView to) {
    _lockedView = to;
    // Front-analyzer dormancy gate: while the front view is hidden in the
    // UI (kCurlFrontViewEnabled == false), a runtime flip TO front updates
    // the locked view (so the host can show the "turn 90°" advisory) but
    // must NOT activate the dormant `CurlFormAnalyzer` front code path.
    // Side analyzer keeps processing — degraded but no worse than today.
    if (to != CurlCameraView.front || kCurlFrontViewEnabled) {
      _form.setView(to);
    }
    _onViewFlipped?.call(from, to);
  }

  void _resetPerRepState() {
    _reachedPeak = false;
    _minAngleThisRep = null;
    _maxAngleAtStart = null;
    _minAngleAtPeak = null;
    _maybeApplyDeferredViewSwitch();
  }

  /// Runs every frame once a view is locked.
  ///
  /// **Pre-seeded sessions short-circuit immediately** — when the user
  /// picked the view at home screen (`_initialView != unknown`), the view
  /// is locked for the session and auto-flip is disabled. Auto-detect
  /// only runs when the session started without a pre-seeded view (legacy
  /// path — no Side picker tap).
  ///
  /// In auto-detect mode, pending view switches apply ONLY when the FSM
  /// is idle (never mid-rep, invariant 10) AND only after
  /// [kViewRedetectHysteresisFrames] consecutive agreeing frames.
  void _updateActiveViewDetection(PoseResult pose, RepState state) {
    // Pre-seeded sessions never auto-flip. The user picked the view at
    // session start (home-screen Side picker → `_initialView`), and that
    // is the contract for the entire session. Auto-flipping during a
    // session was a foot-gun: a brief framing wobble could swap to front,
    // tearing down the side-view analyzer's baselines mid-rep. The user
    // can always finish the workout and start a new one with a different
    // view. Auto-detect remains active ONLY when the session started
    // without a pre-seeded view (`_initialView == unknown`), e.g. the
    // legacy home-screen path that didn't pick a side.
    if (_initialView != CurlCameraView.unknown) {
      _pendingView = CurlCameraView.unknown;
      _pendingViewStreak = 0;
      return;
    }

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
      final from = _lockedView;
      _applyViewFlip(from, _pendingView);
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

    // Same duration flows to both commits for symmetric front-view reps —
    // one physical rep, one measurement, two bucket updates. Pulled once here
    // so every call site sees the same value (no risk of the analyzer's
    // internal state shifting between invocations).
    final concentricDuration = _form.lastConcentricDuration;

    final minAtPeak = _minAngleAtPeak;

    if (symmetric) {
      commit(
        side: ProfileSide.left,
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
        concentricDuration: concentricDuration,
        minAtPeak: minAtPeak,
      );
      commit(
        side: ProfileSide.right,
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
        concentricDuration: concentricDuration,
        minAtPeak: minAtPeak,
      );
    } else {
      // Side-view attribution: prefer the arm ML Kit actually localized
      // this rep, not the user's pre-declared side. ML Kit's anatomical
      // labels don't always match the user's orientation in side
      // recordings — committing to the declared side when the visible
      // arm is the OTHER one would corrupt that bucket. When both arms
      // happen to have bilateral angles (rare in side view), fall back
      // to the declared side. When neither has an angle (shouldn't
      // happen since the rep counted), fall back to declared side too.
      final ProfileSide attributedSide;
      if (leftBilateral != null && rightBilateral == null) {
        attributedSide = ProfileSide.left;
      } else if (rightBilateral != null && leftBilateral == null) {
        attributedSide = ProfileSide.right;
      } else {
        attributedSide = _profileSideForRep();
      }
      commit(
        side: attributedSide,
        view: _lockedView,
        minAngle: minAngle,
        maxAngle: maxAngle,
        concentricDuration: concentricDuration,
        minAtPeak: minAtPeak,
      );
    }
  }

  /// Pick the right analyzer flavor for the given initial view.
  ///
  /// Front (and `unknown`) → [CurlFormAnalyzer]: the battle-tested
  /// implementation. Frozen — never edited as part of side-view fixes.
  ///
  /// Side variants → [CurlSideFormAnalyzer]: independent implementation
  /// that can be iterated freely without touching the front code path.
  ///
  /// `unknown` defaults to the front analyzer because (a) the view
  /// detector hasn't settled yet, (b) front is the more common starting
  /// case, and (c) front analyzer's view-conditionals do gracefully
  /// degrade if the view never resolves to side. The view detector will
  /// re-set the view on the chosen analyzer once it locks.
  static CurlAnalyzer _selectAnalyzer({
    required CurlCameraView initialView,
    required List<Duration> historicalConcentricDurations,
    required List<double>? referenceRepAngleSeries,
    required bool enableDtwScoring,
  }) {
    final isSide =
        initialView == CurlCameraView.sideLeft ||
        initialView == CurlCameraView.sideRight;
    if (isSide) {
      return CurlSideFormAnalyzer(
        historicalConcentricDurations: historicalConcentricDurations,
        referenceRepAngleSeries: referenceRepAngleSeries,
        enableDtwScoring: enableDtwScoring,
      );
    }
    return CurlFormAnalyzer(
      historicalConcentricDurations: historicalConcentricDurations,
      referenceRepAngleSeries: referenceRepAngleSeries,
      enableDtwScoring: enableDtwScoring,
    );
  }
}
