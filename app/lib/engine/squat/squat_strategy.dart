import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/squat_form_thresholds.dart';
import '../../core/squat_rom_defaults.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_landmark.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../exercise_strategy.dart';
import '../form_analyzer_base.dart';
import 'squat_form_analyzer.dart';

/// Fires once per session when the anatomical classifier locks a ratio
/// above [kLongFemurRatioThreshold] — i.e. the user has been classified
/// as a long-femur lifter. The host (typically [WorkoutViewModel]) wires
/// telemetry here; the engine itself stays I/O-free.
///
/// Receives the locked median ratio for telemetry, and may also be used
/// by the persistence layer to remember the result across sessions.
typedef SquatLongFemurDetectedCallback = void Function(double medianRatio);

/// Resolves the [SquatRomThresholdSet] to apply for the next squat rep.
///
/// Called once per rep at IDLE→DESCENDING. The host (typically
/// [WorkoutViewModel]) implements the three-tier chain: personal profile
/// (Tier 1) → in-session auto-cal (Tier 2) → cold-start defaults
/// (Tier 3, sensitivity-modified).
///
/// MUST be synchronous — the FSM hot path cannot await I/O.
typedef SquatRomThresholdsProvider =
    SquatRomThresholdSet Function(int repIndexInSet);

/// Fires once per committed squat rep with the rep's observed extremes.
/// The host wires this to feed the in-session auto-calibrator and (when
/// the user has calibrated) the persistent [SquatRomProfile] bucket.
///
/// Mirrors the shape of [CurlRepCommitCallback]'s extremes-emission
/// arguments — squat omits `side` / `view` because it has neither.
typedef SquatRepExtremesCallback =
    void Function({
      required int repIndex,
      required double minKneeAngle,
      required double maxKneeAngle,
    });

/// Squat FSM encapsulated as a strategy.
///
/// Two scopes of state:
///   - **Per-rep** (cleared at every rep): `_minAngleThisRep`, `_prevHipY`.
///   - **Session** (survives `onNextSet`, cleared on `onReset`):
///     `_repMinAngles`, `_longFemurDetected`, `_effectiveBottomAngle`.
///
/// The session scope is load-bearing — long-femur classification needs
/// cumulative evidence across sets (mirrors original RepCounter behavior).
///
/// Constructor params (Squat Master Rebuild, 2026-04-25):
///   - `variant` — Bodyweight or Barbell back squat. Toggles the
///     analyzer's lean threshold (45° vs 50°).
///   - `longFemurLifter` — "Tall lifter" Settings toggle. Adds +5° to
///     the lean threshold inside the analyzer.
///
/// Long-femur orthogonality: the auto-detected `_longFemurDetected` flag
/// (this class) widens the BOTTOM gate from 90° → 100°. The
/// user-facing `longFemurLifter` toggle (analyzer) widens the lean
/// threshold by +5°. The two flags target different thresholds — they
/// never stack on the same one.
class SquatStrategy extends ExerciseStrategy {
  SquatStrategy({
    this.variant = SquatVariant.bodyweight,
    this.longFemurLifter = false,
    SquatFormThresholds formThresholds = SquatFormThresholds.defaults,
    SquatRomThresholdSet romThresholds = SquatRomDefaults.defaults,
    SquatRomThresholdsProvider? thresholdsProvider,
    SquatRepExtremesCallback? onRepExtremes,
    SquatLongFemurDetectedCallback? onLongFemurDetected,
    double? persistedFemurTorsoRatio,
    List<Duration> historicalConcentricDurations = const [],
  }) : _romThresholds = romThresholds,
       _thresholdsProvider = thresholdsProvider,
       _onRepExtremes = onRepExtremes,
       _onLongFemurDetected = onLongFemurDetected,
       _activeThresholds = romThresholds,
       _form = SquatFormAnalyzer(
         variant: variant,
         longFemurLifter: longFemurLifter,
         formThresholds: formThresholds,
         historicalConcentricDurations: historicalConcentricDurations,
       ) {
    // Returning user with a stored ratio: seed the classifier so we don't
    // wait 5 high-confidence frames before adapting. The strategy still
    // honors the threshold check — a persisted ratio ≤ 0.60 simply means
    // the classifier is locked but [kLongFemurRatioThreshold] gates the
    // adaptation, so behavior matches the rep-history fallback path.
    if (persistedFemurTorsoRatio != null) {
      _femurClassifier.seedFromPersisted(persistedFemurTorsoRatio);
    }
  }

  final SquatVariant variant;
  final bool longFemurLifter;

  /// Construction-time fallback threshold tuple. When [_thresholdsProvider]
  /// is non-null, the host's tier-priority resolver supersedes this on
  /// every IDLE→DESCENDING transition. When null, this constructor-time
  /// tuple is used for every rep — preserves the Part 1 behavior where
  /// `SquatStrategy(romThresholds: ...)` configures a fixed sensitivity.
  final SquatRomThresholdSet _romThresholds;

  /// Host-provided tier-priority resolver. Wired by [WorkoutViewModel] when
  /// a session has a [SquatRomProfile] or in-session auto-calibrator that
  /// might supersede the cold-start tuple. Null in tests and in any path
  /// that doesn't need the resolver.
  final SquatRomThresholdsProvider? _thresholdsProvider;

  /// Per-rep extremes callback. Fires after every committed rep with the
  /// observed min/max knee angles. The host feeds these to the auto-cal
  /// (and, when calibrated, the persistent bucket).
  final SquatRepExtremesCallback? _onRepExtremes;

  final SquatFormAnalyzer _form;

  /// Anatomical long-femur classifier — locks a femur/torso ratio over a
  /// window of ≥ [kFemurTorsoMinSamples] high-confidence frames. Drives
  /// the "from rep 1" long-femur adaptation; replaces the rep-history
  /// heuristic for users whose classification stabilizes before the
  /// rep-history path would trigger.
  final _FemurTorsoClassifier _femurClassifier = _FemurTorsoClassifier();

  /// Fires once when the classifier locks AND the ratio clears
  /// [kLongFemurRatioThreshold]. Host wires telemetry here so this engine
  /// file stays pure-Dart (no `package:flutter`, no I/O).
  final SquatLongFemurDetectedCallback? _onLongFemurDetected;

  /// True once [_onLongFemurDetected] has fired this session. Prevents
  /// duplicate emissions if the FSM passes through IDLE multiple times.
  bool _longFemurEmitted = false;

  // Per-rep.
  double? _prevHipY;
  double? _minAngleThisRep;
  double? _maxAngleThisRep;

  /// Timestamp at which the FSM most recently entered BOTTOM. Used to
  /// enforce [kSquatBottomDwellMs] before BOTTOM → ASCENDING can commit.
  /// Cleared on every reset path so a stale value from a prior rep cannot
  /// satisfy the dwell check on the next entry. Added 2026-05-15.
  DateTime? _bottomEntryTs;

  /// Thresholds resolved at IDLE→DESCENDING. Held for the rest of the rep
  /// so Tier 1 / Tier 2 can't fight over thresholds mid-rep. Mirrors curl's
  /// `_activeThresholds` invariant. Falls back to [_romThresholds] when no
  /// host provider is wired.
  SquatRomThresholdSet _activeThresholds;

  /// Monotonic rep counter for the [SquatRepExtremesCallback] — captured
  /// at construction and incremented on every commit.
  int _repCommitCount = 0;

  // Session-scoped long-femur detection.
  final List<double> _repMinAngles = [];
  bool _longFemurDetected = false;
  double _effectiveBottomAngle = kSquatBottomAngle;

  @override
  ExerciseType get exercise => ExerciseType.squat;

  @override
  FormAnalyzerBase get formAnalyzer => _form;

  @override
  List<int> get requiredLandmarkIndices =>
      ExerciseRequirements.forExercise(ExerciseType.squat).landmarkIndices;

  /// Current effective bottom angle — relaxed if long-femur auto-detected.
  /// Exposed primarily for tests and for the summary screen.
  double get effectiveBottomAngle => _effectiveBottomAngle;

  /// Quality score for the most recently committed rep. Null until the
  /// first rep commits in the current session.
  double? get lastRepQuality => _form.lastRepQuality;

  /// Ascent (concentric/lift) duration of the most recently committed
  /// rep. Null on a rep with no measured ascent. Pass-through to the
  /// analyzer — consumed by the host's `_handleSquatRepCommit` for
  /// `concentric_ms` persistence + the cross-session fatigue baseline.
  Duration? get lastConcentricDuration => _form.lastConcentricDuration;

  /// Most recent peak forward-lean (deg). Null until first commit.
  double? get lastRepLeanDeg => _form.lastRepLeanDeg;

  /// Most recent peak knee-shift ratio. Null until first commit.
  double? get lastRepKneeShiftRatio => _form.lastRepKneeShiftRatio;

  /// Most recent peak heel-lift ratio. Null until first commit.
  double? get lastRepHeelLiftRatio => _form.lastRepHeelLiftRatio;

  /// Fraction of the most recent rep's evaluated frames whose forward lean
  /// exceeded the active threshold. Null until first commit OR when the rep
  /// had no evaluable lean frames. The host reads this for the `squat.rep`
  /// `lean_exceed_frac` telemetry field.
  double? get lastRepLeanExceedFrac => _form.lastRepLeanExceedFrac;

  /// Signed lean at the |lean| peak of the most recent rep (forward = +,
  /// backward = −). Bug-4 sign-convention diagnostic. The host reads this
  /// for the `squat.rep` `signed_lean=` field.
  double? get lastRepSignedLeanAtPeak => _form.lastRepSignedLeanAtPeak;

  /// Frames in the most recent rep that fired `excessiveBackwardLean`.
  /// The host reads this for the `squat.rep` `backward_lean_frames=` field.
  int get lastRepBackwardLeanFrameCount => _form.lastRepBackwardLeanFrameCount;

  /// Most recent hip-lead ratio (mean v_y_hip / mean v_y_shoulder over the
  /// first 30% of ASCENDING). Null until the hip-lead check has run AND
  /// the window contained ≥ 4 valid velocity pairs. The host reads this
  /// for the `squat.hip_lead` telemetry line at rep commit.
  double? get lastRepHipLeadRatio => _form.lastRepHipLeadRatio;

  /// Most recent knee-led-descent ratio (`|Δknee.x| / Δhip.y_down`,
  /// leg-length-normalized, over the shared early-descent window). Null
  /// between rep commit and the next window close. The host reads this for
  /// the `squat.knee_led` telemetry line at rep commit.
  double? get lastRepKneeLedRatio => _form.lastRepKneeLedRatio;

  /// Frames accumulated during the most recent ASCENDING window — the
  /// `ascending_frame_count` field of the `squat.hip_lead` telemetry line.
  int get ascendingFrameCount => _form.ascendingFrameCount;

  /// Frames sampled inside the most recent early-descent window for the
  /// knee-led check — the `window_frames` field of the `squat.knee_led`
  /// telemetry line.
  int get kneeLedSampleCount => _form.kneeLedSampleCount;

  /// Live signed forward-lean angle (deg) from the most recent frame.
  /// Positive = forward; negative = backward; null when the analyzer
  /// hasn't seen a high-confidence shoulder/hip pair yet. The HUD reads
  /// this to render the real-time lean indicator (Cue 3, 2026-05-15).
  double? get currentSignedLeanDeg => _form.currentSignedLeanDeg;

  /// Active lean warning threshold (variant + tall-lifter boost). Useful
  /// for tests asserting orthogonality of long-femur signals.
  double get leanWarnDeg => _form.leanWarnDeg;

  @override
  double? computePrimaryAngle(PoseResult pose) {
    final leftAngle = angleDeg(
      pose.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftKnee, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.leftAnkle, minConfidence: kMinLandmarkConfidence),
    );
    final rightAngle = angleDeg(
      pose.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightKnee, minConfidence: kMinLandmarkConfidence),
      pose.landmark(LM.rightAnkle, minConfidence: kMinLandmarkConfidence),
    );
    if (leftAngle != null && rightAngle != null) {
      return (leftAngle + rightAngle) / 2.0;
    }
    return leftAngle ?? rightAngle;
  }

  /// Squat override of the no-op base implementation. Feeds the
  /// anatomical classifier with high-confidence frames during
  /// SETUP_CHECK / COUNTDOWN so a returning user (or one in the first
  /// few seconds of a session) can already lock the femur/torso ratio
  /// before the first rep starts. The classifier is no-op once locked.
  ///
  /// The return value mirrors the curl-specific signature
  /// ([CurlCameraView]) for shape compatibility — squat has no view, so
  /// we always return [CurlCameraView.unknown].
  @override
  CurlCameraView updateSetupView(PoseResult pose) {
    _femurClassifier.feed(pose);
    return CurlCameraView.unknown;
  }

  @override
  StrategyFrameOutput tick(StrategyFrameInput input) {
    final smoothed = input.smoothedAngle;
    final pose = input.pose;
    final hipY = _computeHipY(pose);

    // Keep classifier learning during active phases too — high-confidence
    // landmarks are easier to come by while the user is standing than
    // mid-squat, but the no-op-once-locked guard means this is free.
    _femurClassifier.feed(pose);

    // Track minimum knee angle during active descent for long-femur detection.
    if (input.state == RepState.descending || input.state == RepState.bottom) {
      if (_minAngleThisRep == null || smoothed < _minAngleThisRep!) {
        _minAngleThisRep = smoothed;
      }
      _form.trackAngle(smoothed);
    }

    // Track most-extended knee angle while the user is standing pre-rep.
    // This is the natural max for the upcoming rep — capturing it across
    // every IDLE frame is robust to partial-descent-then-reverse paths
    // that would otherwise leave a stale max at IDLE→DESCENDING.
    if (input.state == RepState.idle) {
      if (_maxAngleThisRep == null || smoothed > _maxAngleThisRep!) {
        _maxAngleThisRep = smoothed;
      }
    }

    var nextState = input.state;
    var repCommitted = false;
    var errors = <FormError>[];

    // Frame-level form evaluation runs in all three active phases. Lean +
    // heel-lift + knee-shift express themselves throughout the descent,
    // not only on the way up — so we evaluate during DESCENDING + BOTTOM
    // + ASCENDING to catch the worst-frame in each metric.
    if (input.state == RepState.descending ||
        input.state == RepState.bottom ||
        input.state == RepState.ascending) {
      errors = _form.evaluate(pose, now: input.now);
    }

    switch (input.state) {
      case RepState.idle:
        // Anatomical adaptation: if classifier has locked AND ratio clears
        // the long-femur threshold, relax the BOTTOM gate from rep 1.
        // Idempotent — `_longFemurDetected` guards re-entry. Logged via
        // the host callback so the engine stays I/O-free.
        _maybeApplyAnatomicalLongFemur();

        // Resolve thresholds NOW. The host's tier-priority chain runs once
        // per rep and the result is locked for the rest of this rep — the
        // FSM never re-resolves mid-rep (threshold-lock invariant). When
        // no provider is wired, fall back to the construction-time tuple.
        //
        // Defensive guard (2026-05-21): wrap the host call in try/catch so
        // a thrown exception in the tier-priority resolver (DB read, null
        // deref in `SquatRomProfile`, etc.) doesn't propagate up through
        // `RepCounter.update` and stall the entire pose pipeline. On
        // failure we silently fall back to the construction-time tuple.
        // The assert-only print keeps this engine pure-Dart (no
        // `package:flutter`, no I/O) while still surfacing the failure in
        // dev builds where the offline replay harness runs.
        SquatRomThresholdSet resolved;
        try {
          resolved =
              _thresholdsProvider?.call(input.repIndexInSet) ?? _romThresholds;
        } catch (e) {
          resolved = _romThresholds;
          assert(() {
            // ignore: avoid_print
            print(
              '[SquatStrategy] thresholdsProvider threw ($e) — '
              'fallback to construction-time tuple',
            );
            return true;
          }());
        }
        if (smoothed < resolved.startAngle) {
          _activeThresholds = resolved;
          // `_maxAngleThisRep` is tracked continuously while IDLE above,
          // so it already holds the most-extended angle observed during
          // the standing pause. No capture needed here.
          nextState = RepState.descending;
          _form.onRepStart(pose);
          // Eccentric (descent) phase clock starts here.
          _form.stampDescentStart(input.now);
        }
      case RepState.descending:
        if (smoothed < _effectiveBottomAngle) {
          // Stamp BOTTOM entry for the dwell gate at BOTTOM → ASCENDING.
          // Captured here (not on the next frame) so dwell measurement
          // starts the moment we cross the depth threshold.
          _bottomEntryTs = input.now;
          nextState = RepState.bottom;
        } else if (smoothed > _activeThresholds.startAngle) {
          nextState = RepState.idle;
          _resetPerRepState();
        }
      case RepState.bottom:
        // Three possible transitions out of BOTTOM:
        //   1. BOTTOM → IDLE (timeout — no rep emitted): the user held the
        //      bottom for longer than `kSquatBottomMaxHoldMs`. Either
        //      mid-rep occlusion or a rest pause. Bail to IDLE so the
        //      analyzer's per-rep state is fresh for the next attempt.
        //      Fires BEFORE the 5s stuck-state watchdog in RepCounter,
        //      which would also reset but coarser.
        //   2. BOTTOM → ASCENDING (rep in progress): dwell satisfied AND
        //      either the knee angle is meaningfully rising OR the hip is
        //      rising in screen-Y. Angle-OR-hip prevents single-frame
        //      pose-jitter from committing a rep with no real ascent (the
        //      original hipY-only gate misfired at 60fps on ~1px noise).
        //   3. (Implicit) BOTTOM stays BOTTOM if dwell hasn't passed yet
        //      or neither rising signal is present.
        final bottomAgeMs = _bottomEntryTs == null
            ? 0
            : input.now.difference(_bottomEntryTs!).inMilliseconds;
        if (bottomAgeMs >= kSquatBottomMaxHoldMs) {
          nextState = RepState.idle;
          _resetPerRepState();
          break;
        }
        final bottomDwellOk =
            _bottomEntryTs != null && bottomAgeMs >= kSquatBottomDwellMs;
        // Angle-based rising signal: knee has re-extended at least 2°
        // past the rep's deepest point. Sign-immune to screen-Y
        // conventions and immune to landmark Y-jitter at the millimeter
        // scale (a 2° knee swing is ~3-4 cm of foot-to-hip travel).
        final angleRising =
            _minAngleThisRep != null && smoothed > _minAngleThisRep! + 2.0;
        // Screen-Y rising signal (legacy): Y=0 at top, so rising = Y
        // decreasing frame-over-frame. Kept as a complementary gate so
        // a slow grind out of the hole (knee angle moves <2° between
        // frames) can still commit if hip motion is clear.
        final hipRising =
            hipY != null && _prevHipY != null && hipY < _prevHipY!;
        if (bottomDwellOk && (angleRising || hipRising)) {
          // Arm the analyzer's per-frame hip+shoulder Y accumulator —
          // hip-lead is evaluated over the first 30% of ASCENDING.
          _form.onAscendingStart();
          // Concentric (ascent) phase clock starts; closes the eccentric
          // timer inside the analyzer.
          _form.stampAscentStart(input.now);
          nextState = RepState.ascending;
        }
      case RepState.ascending:
        if (smoothed >= _activeThresholds.endAngle) {
          // Close the hip-lead window BEFORE consuming completion errors —
          // `consumeCompletionErrorsWithDepth` reads the flag set inside
          // `onAscendingEnd` and folds `FormError.hipLead` into its
          // returned set. Calling it after the consume would drop the
          // error entirely.
          _form.onAscendingEnd();
          // Close the concentric timer BEFORE consuming completion errors
          // so the squat tempo/fatigue signals see this rep's final
          // ascent duration. (Does NOT yet append to the rolling window —
          // that waits for the half-squat veto verdict below.)
          _form.stampAscentEnd(input.now);
          final completionErrors = _form.consumeCompletionErrorsWithDepth(
            _effectiveBottomAngle,
          );
          errors = [...errors, ...completionErrors];
          _maybeUpdateLongFemur();
          _emitRepExtremes();
          // Half-squat veto (2026-05-15): a rep that never reached the
          // effective bottom angle still emits feedback ("Go deeper") but
          // does NOT increment the counter. Pre-2026-05-15 the rep would
          // commit unconditionally — the depth signal was *informational*
          // rather than *gating*. The veto preserves the feedback path so
          // the user still hears the cue but turns the half-squat into a
          // miss instead of a counted partial. FSM still returns to IDLE
          // so the user can re-attempt without a stale ASCENDING state.
          final missedDepth = completionErrors.contains(FormError.squatDepth);
          repCommitted = !missedDepth;
          // Only a COMMITTED rep feeds the tempo-consistency / fatigue
          // rolling window. A vetoed half-squat already emitted its
          // per-rep too-fast cue (feedback) above, but its abnormal
          // ascent duration must not skew the window — see
          // SquatFormAnalyzer.commitAscentToWindow doc.
          if (repCommitted) {
            _form.commitAscentToWindow();
          }
          nextState = RepState.idle;
          _resetPerRepState();
        }
      default:
        break;
    }

    _prevHipY = hipY;

    return StrategyFrameOutput(
      nextState: nextState,
      repCommitted: repCommitted,
      formErrors: errors,
    );
  }

  @override
  void onNextSet() {
    // Per-rep cleared; session-scoped long-femur state survives — both the
    // rep-history accumulator and the anatomical classifier (anatomy is
    // session-scoped, not set-scoped).
    _prevHipY = null;
    _minAngleThisRep = null;
    _maxAngleThisRep = null;
    _bottomEntryTs = null;
    _form.reset();
  }

  @override
  void onReset() {
    _prevHipY = null;
    _minAngleThisRep = null;
    _maxAngleThisRep = null;
    _bottomEntryTs = null;
    _repMinAngles.clear();
    _longFemurDetected = false;
    _longFemurEmitted = false;
    _effectiveBottomAngle = kSquatBottomAngle;
    _repCommitCount = 0;
    _activeThresholds = _romThresholds;
    _femurClassifier.reset();
    _form.reset();
  }

  /// Apply the anatomical-classifier path: if the classifier has locked AND
  /// the locked ratio clears [kLongFemurRatioThreshold], relax the BOTTOM
  /// gate immediately. Fires the host callback exactly once per session.
  void _maybeApplyAnatomicalLongFemur() {
    if (_longFemurDetected) return;
    final ratio = _femurClassifier.lockedRatio;
    if (ratio == null) return;
    if (ratio <= kLongFemurRatioThreshold) return;
    _longFemurDetected = true;
    _effectiveBottomAngle = kLongFemurBottomAngle;
    if (!_longFemurEmitted) {
      _longFemurEmitted = true;
      _onLongFemurDetected?.call(ratio);
    }
  }

  /// Emit the committed rep's extremes to the host. No-op when either
  /// extreme is missing (defensive against shape-changes upstream — both
  /// should be captured by the time the FSM reaches ASCENDING commit).
  void _emitRepExtremes() {
    final cb = _onRepExtremes;
    if (cb == null) return;
    final minA = _minAngleThisRep;
    final maxA = _maxAngleThisRep;
    if (minA == null || maxA == null) return;
    cb(repIndex: _repCommitCount, minKneeAngle: minA, maxKneeAngle: maxA);
    _repCommitCount++;
  }

  // ── Internals ─────────────────────────────────────────────────────

  void _resetPerRepState() {
    _prevHipY = null;
    _minAngleThisRep = null;
    _maxAngleThisRep = null;
    _bottomEntryTs = null;
  }

  /// Long-femur adaptation: if the user consistently bottoms between
  /// [kSquatLongFemurDetectFloorAngle] (anatomical 90° parallel) and
  /// [kLongFemurBottomAngle] for [kLongFemurDetectReps] consecutive reps,
  /// relax the bottom threshold.
  ///
  /// The lower bound is [kSquatLongFemurDetectFloorAngle] (pinned 90°), NOT
  /// [kSquatBottomAngle] (the depth gate, tightened to 80° on 2026-05-16).
  /// Anchoring here keeps long-femur detection tied to the anatomical
  /// parallel reference — a user squatting at 82-88° is "not deep enough
  /// yet," not "anatomically long-femured," and must not auto-relax the
  /// gate out from under themselves.
  void _maybeUpdateLongFemur() {
    if (_longFemurDetected) return;
    if (_minAngleThisRep == null) return;

    _repMinAngles.add(_minAngleThisRep!);
    if (_repMinAngles.length < kLongFemurDetectReps) return;

    final allAboveParallel = _repMinAngles.every(
      (a) => a > kSquatLongFemurDetectFloorAngle,
    );
    final allReached100 = _repMinAngles.every(
      (a) => a <= kLongFemurBottomAngle,
    );
    if (allAboveParallel && allReached100) {
      _longFemurDetected = true;
      _effectiveBottomAngle = kLongFemurBottomAngle;
      // Log only in checked builds — keeps squat_strategy.dart pure-Dart
      // so the offline replay harness (tools/dataset_analysis/dart_replay)
      // can run without pulling in package:flutter.
      assert(() {
        // ignore: avoid_print
        print(
          '[SquatStrategy] Long-femur detected — relaxing BOTTOM to '
          '$kLongFemurBottomAngle°',
        );
        return true;
      }());
    }
  }

  double? _computeHipY(PoseResult r) {
    final left = r.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence);
    final right = r.landmark(
      LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    if (left != null && right != null) return (left.y + right.y) / 2.0;
    return left?.y ?? right?.y;
  }
}

/// Anatomical long-femur classifier (file-private).
///
/// Collects per-frame femur/torso length ratios from high-confidence
/// landmarks. Once ≥ [kFemurTorsoMinSamples] samples accumulate in the
/// sliding window of size [kFemurTorsoWindowSize], the classifier
/// computes the median, locks the result, and ignores further input.
///
/// Why median over the window:
///   - ML Kit's first ~30 frames carry transient jitter; a single-frame
///     ratio would mis-classify a non-trivial fraction of users.
///   - The median is robust to outliers but cheap to compute over the
///     small bounded window.
///
/// Why a hard lock:
///   - Anatomy doesn't change mid-session. Re-evaluating after lock
///     would flap the BOTTOM gate based on landmark noise.
///   - A returning user with a persisted ratio is seeded via
///     [seedFromPersisted] so the classifier starts locked.
///
/// Confidence floor reuses [kSetupCurlMinConfidence] (0.65) — the same
/// floor curl uses for setup-quality gate decisions. Choosing one
/// reused constant keeps the "what does high-confidence mean here?"
/// question consistent across exercises.
class _FemurTorsoClassifier {
  final List<double> _samples = [];
  bool _locked = false;
  double? _lockedRatio;

  /// The locked ratio once the classifier has accumulated enough samples,
  /// else null. Stable for the rest of the session once non-null.
  double? get lockedRatio => _lockedRatio;

  /// Feed one frame. Returns the locked ratio when locked, else null.
  /// Idempotent once locked — the early-return at the top short-circuits.
  double? feed(PoseResult p) {
    if (_locked) return _lockedRatio;
    final ratio = _computeRatio(p);
    if (ratio == null) return null;
    _samples.add(ratio);
    if (_samples.length > kFemurTorsoWindowSize) {
      _samples.removeAt(0);
    }
    if (_samples.length < kFemurTorsoMinSamples) return null;
    final sorted = List<double>.from(_samples)..sort();
    _lockedRatio = sorted[sorted.length ~/ 2];
    _locked = true;
    return _lockedRatio;
  }

  /// Compute femur/torso ratio for one pose. Picks the higher-average
  /// confidence side (left or right) so the result is robust to single-side
  /// occlusion. Returns null if neither side clears the confidence floor.
  double? _computeRatio(PoseResult p) {
    final leftHip = p.landmark(LM.leftHip);
    final leftKnee = p.landmark(LM.leftKnee);
    final leftShoulder = p.landmark(LM.leftShoulder);
    final rightHip = p.landmark(LM.rightHip);
    final rightKnee = p.landmark(LM.rightKnee);
    final rightShoulder = p.landmark(LM.rightShoulder);

    final leftRatio = _ratioForSide(leftHip, leftKnee, leftShoulder);
    final rightRatio = _ratioForSide(rightHip, rightKnee, rightShoulder);

    if (leftRatio == null && rightRatio == null) return null;
    if (leftRatio == null) return rightRatio;
    if (rightRatio == null) return leftRatio;

    // Both sides cleared the gate — pick the higher-confidence one.
    final leftConf =
        ((leftHip!.confidence +
            leftKnee!.confidence +
            leftShoulder!.confidence) /
        3.0);
    final rightConf =
        ((rightHip!.confidence +
            rightKnee!.confidence +
            rightShoulder!.confidence) /
        3.0);
    return leftConf >= rightConf ? leftRatio : rightRatio;
  }

  double? _ratioForSide(
    PoseLandmark? hip,
    PoseLandmark? knee,
    PoseLandmark? shoulder,
  ) {
    if (hip == null || knee == null || shoulder == null) return null;
    if (hip.confidence < kSetupCurlMinConfidence) return null;
    if (knee.confidence < kSetupCurlMinConfidence) return null;
    if (shoulder.confidence < kSetupCurlMinConfidence) return null;
    final femur = _dist(hip, knee);
    final torso = _dist(shoulder, hip);
    // Guard against degenerate poses where the torso collapses to a point —
    // a divide-by-zero here would produce ±inf and poison the median.
    if (torso < 1e-6) return null;
    return femur / torso;
  }

  static double _dist(PoseLandmark a, PoseLandmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Clear all state — called from [SquatStrategy.onReset]. NOT called from
  /// `onNextSet`: anatomy is session-scoped, not set-scoped.
  void reset() {
    _samples.clear();
    _locked = false;
    _lockedRatio = null;
  }

  /// Seed from a previously persisted ratio (returning user). The classifier
  /// locks immediately so the strategy can adapt on rep 1 without waiting
  /// for the sample-gathering phase.
  void seedFromPersisted(double ratio) {
    _lockedRatio = ratio;
    _locked = true;
  }
}
