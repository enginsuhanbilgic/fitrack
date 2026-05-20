import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/form_thresholds.dart';
import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';
import 'curl_form_analyzer_extras.dart';

/// Side-view-only form analyzer for biceps curl.
///
/// **Strict isolation from `CurlFormAnalyzer` (front).** This class is a
/// complete, independent implementation of the curl analyzer contract —
/// it shares ONLY [FormAnalyzerBase] and [CurlFormAnalyzerExtras] with
/// the front analyzer. No shared base class beyond those abstract
/// contracts. Reason: the side-view code path has been the source of
/// most recent thrashing (view detection, landmark gating, threshold
/// derivation), and the codebase explicitly chose to isolate side from
/// front so iteration on side cannot regress front.
///
/// Frame-level errors (evaluated during CONCENTRIC/ECCENTRIC):
///   - `depthSwing`: forward sagittal trunk lean — trunk-from-vertical
///     angle delta above [kTorsoLeanThresholdDeg]. TTS cue: "Don't rock
///     forward". Replaces the prior `torsoSwing` lean leg (renamed 2026-05-21
///     so the cue and the math agree on what they measure).
///   - `shoulderArc`: hip-pivot rotation around the vertical axis. Computed
///     as the X-component (only) of the shoulder displacement in hip-relative
///     coordinates, normalized by torso length, > [kSwingThreshold]. The Y
///     component is intentionally dropped so a forward sagittal lean (which
///     also moves the shoulder in Y) does not re-introduce the lean confound.
///   - `elbowDrift`: torso-perpendicular projection of the elbow offset
///     `(E − S) · n̂ / |S − H|` — magnitude > [kDriftThreshold]. Lean-invariant
///     by construction; sign is preserved on `lastSignedElbowDriftRatio` for
///     telemetry. See `docs/biceps/BICEPS_CURL_SIDE_VIEW_SPEC.md §B`.
///
/// `FormError.torsoSwing` is intentionally NOT emitted by the side analyzer.
/// Lateral momentum in the user's frontal plane projects into screen depth
/// in a 2D side-view camera and is geometrically unobservable here. The
/// enum value still exists for legacy deserialization and potential future
/// front-view use.
///
/// Rep-boundary errors:
///   - `shortRomStart`, `shortRomPeak`: classified against active thresholds.
///   - `eccentricTooFast`, `concentricTooFast`, `tempoInconsistent`: tempo.
///   - `fatigue`: concentric slowdown over the session.
///
/// Features intentionally NOT present (front-only):
///   - Bilateral asymmetry — only one arm visible in side view.
///
/// Note: `depthSwing` USED to mean "front-view scale-invariant detector of
/// torso-toward-camera motion" — that detector was deleted with the rest
/// of the front analyzer on 2026-05-13. The enum value was repurposed
/// 2026-05-21 for the side-view forward-lean cue described above (the cue
/// strings "Don't rock forward" / "Rocking Forward" were always aligned
/// with forward lean and remain unchanged).
class CurlSideFormAnalyzer extends CurlAnalyzer {
  CurlSideFormAnalyzer({
    FormThresholds formThresholds = FormThresholds.medium,
    List<Duration> historicalConcentricDurations = const [],
  }) : _formThresholds = formThresholds,
       _historicalConcentricDurations = List<Duration>.unmodifiable(
         historicalConcentricDurations,
       );

  final FormThresholds _formThresholds;

  // ── View ──────────────────────────────────────────────
  /// User-declared / view-detector hint of which side faces the camera.
  /// Defaults to [CurlCameraView.sideLeft]; the host may override via
  /// [setView]. The analyzer rejects [CurlCameraView.front] — a side
  /// analyzer should never be running in front view.
  ///
  /// **Not used as a hard landmark selector.** ML Kit's anatomical labels
  /// don't reliably match the user's declared orientation in side
  /// recordings (front-camera mirroring + 2D pose ambiguity). Each rep
  /// resolves [_activeArm] from the pose itself at [onRepStart] — the
  /// declared view is only a fall-back tiebreaker when both arms have
  /// equal confidence (which is rare).
  CurlCameraView _view = CurlCameraView.sideLeft;

  /// Which anatomical arm the analyzer is reading this rep — resolved at
  /// [onRepStart] from landmark confidence and frozen for the rep. Set
  /// to `true` for left-arm landmarks (`LM.leftShoulder`, `leftHip`,
  /// `leftElbow`); `false` for right. Defaults to the [_view] hint when
  /// the rep starts before any landmarks are available.
  bool _activeArmIsLeft = true;

  // ── Active thresholds ────────────────────────────────
  RomThresholds _activeThresholds = RomThresholds.global();

  // ── Per-rep state ────────────────────────────────────
  PoseResult? _repStartSnapshot;
  bool _shortRomStartPending = false;
  bool _shortRomPeakPending = false;

  // ── Tempo tracking ───────────────────────────────────
  DateTime? _concentricStart;
  DateTime? _eccentricStart;
  Duration? _lastEccentricDuration;
  Duration? _lastConcentricDuration;
  int _eccentricTooFastCount = 0;
  int _concentricTooFastCount = 0;
  int _tempoInconsistentCount = 0;
  int _tempoReArmRepsRemaining = 0;
  bool _lastRepTempoInconsistent = false;
  final List<Duration> _concentricDurations = [];

  // ── Fatigue ──────────────────────────────────────────
  bool _fatigueFired = false;
  final List<Duration> _historicalConcentricDurations;

  // ── Per-rep extremes for quality scoring ─────────────
  double _maxDriftRatio = 0.0;
  double _maxLeanDeltaDeg = 0.0;
  double _maxShoulderArcRatio = 0.0;
  double _maxShrugRatio = 0.0;
  double _maxBackLeanDeg = 0.0;

  /// Most recent signed perpendicular elbow-offset ratio. Sign convention:
  /// positive = elbow on the side of n̂ where n̂ = (−u_y, u_x) and
  /// u = (S − H)/|S − H|. Null when landmarks are missing or torso length
  /// collapsed. Cleared at rep boundary.
  double? _lastSignedElbowDriftRatio;

  /// Signed perpendicular elbow-offset ratio captured at the frame where
  /// `_maxDriftRatio` peaked this rep. Distinct from
  /// [_lastSignedElbowDriftRatio] which is just the most recent frame's
  /// value. Persisted as `biceps_elbow_drift_signed` (schema v5) so the
  /// retune pipeline can split "elbow forward" (front-delt cheat) vs.
  /// "elbow back" (rare; setup issue) without ambiguity.
  double? _signedElbowDriftRatioAtMax;

  // ── Sustained elbow-drift gate (per-rep) ──────────────
  /// Count of evaluated frames this rep whose drift ratio cleared BOTH the
  /// effective dead-band AND the audit threshold. Numerator of the
  /// sustained-drift fraction. A single jittery off-line frame in an
  /// otherwise-clean rep no longer fires `elbowDrift` — the verdict is the
  /// per-rep fraction, decided at commit. Mirrors squat's
  /// `_leanExceedFrameCount`. Reset at `onRepStart`, at rep commit, and in
  /// `reset()`.
  int _driftExceedFrameCount = 0;

  /// Count of frames this rep with a usable shoulder/hip/elbow triple
  /// (torso vector resolvable). Denominator of the sustained-drift
  /// fraction — only frames the drift metric could actually be computed on
  /// count. Mirrors squat's `_leanTotalEvalFrameCount`. Reset alongside
  /// [_driftExceedFrameCount].
  int _driftTotalEvalFrameCount = 0;

  // ── Side-view baselines (snapshot at rep start) ──────
  double? _baselineTorsoAngle;
  double? _baselineTorsoAngleSigned;
  double? _baselineShoulderRelX;
  double? _baselineShoulderRelY;
  bool? _facingRight;

  // ── Arm-resolution telemetry (snapshot at rep start) ─
  // Captured so `CurlStrategy` can emit a `rep.arm_resolved` log line
  // showing exactly why `_activeArmIsLeft` flipped — without this, a
  // user-vs-analyzer side mismatch is undebuggable. Updated only at
  // `onRepStart`; preserved across the rep so the commit-time logger
  // sees the same numbers `_resolveActiveArm` did.
  double _leftArmConfSum = 0.0;
  double _rightArmConfSum = 0.0;

  // ── Quality bookkeeping ──────────────────────────────
  double _lastRepQuality = 1.0;
  final List<double> _repQualities = [];

  // ─────────────────────────────────────────────────────
  // FormAnalyzerBase + CurlFormAnalyzerExtras contract
  // ─────────────────────────────────────────────────────

  @override
  void setView(CurlCameraView view) {
    // Side analyzer only meaningfully tracks side variants. Reject front
    // — if the host wired it incorrectly, fall back to sideLeft so the
    // analyzer keeps producing usable output rather than crashing.
    if (view == CurlCameraView.front || view == CurlCameraView.unknown) {
      _view = CurlCameraView.sideLeft;
    } else {
      _view = view;
    }
  }

  @override
  void setActiveThresholds(RomThresholds thresholds) {
    _activeThresholds = thresholds;
  }

  @override
  void onRepStart(PoseResult snapshot) {
    _repStartSnapshot = snapshot;
    _shortRomStartPending = false;
    _shortRomPeakPending = false;
    _concentricStart = DateTime.now();
    _eccentricStart = null;
    _lastEccentricDuration = null;
    _maxDriftRatio = 0.0;
    _maxLeanDeltaDeg = 0.0;
    _maxShoulderArcRatio = 0.0;
    _maxShrugRatio = 0.0;
    _maxBackLeanDeg = 0.0;
    _lastSignedElbowDriftRatio = null;
    _signedElbowDriftRatioAtMax = null;
    _driftExceedFrameCount = 0;
    _driftTotalEvalFrameCount = 0;
    // Resolve the active arm BEFORE reading any per-side baselines.
    // Picks the arm with stronger landmark presence in this snapshot —
    // robust against front-camera mirroring + ML Kit's labelling
    // ambiguity in side recordings. Falls back to the declared view
    // when the snapshot can't decide (no landmarks visible yet).
    _activeArmIsLeft = _resolveActiveArm(snapshot);
    _baselineTorsoAngle = _torsoAngle(snapshot, _activeArmIsLeft);
    _baselineTorsoAngleSigned = _torsoAngleSigned(snapshot, _activeArmIsLeft);
    _facingRight = _detectFacingRight(snapshot, _activeArmIsLeft);
    final useLeft = _activeArmIsLeft;
    final shoulder = snapshot.landmark(
      useLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = snapshot.landmark(
      useLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    if (shoulder != null && hip != null) {
      _baselineShoulderRelX = shoulder.x - hip.x;
      _baselineShoulderRelY = shoulder.y - hip.y;
    } else {
      _baselineShoulderRelX = null;
      _baselineShoulderRelY = null;
    }
  }

  @override
  void onPeakReached() {
    if (_concentricStart != null) {
      final d = DateTime.now().difference(_concentricStart!);
      _concentricDurations.add(d);
      _lastConcentricDuration = d;
    }
  }

  @override
  void onEccentricStart() {
    _eccentricStart = DateTime.now();
  }

  @override
  void onAbortedRep({
    required double maxAngleAtStart,
    required double minAngleReached,
  }) {
    if (minAngleReached > _activeThresholds.peakAngle + kShortRomTolerance) {
      _shortRomPeakPending = true;
    } else if (maxAngleAtStart <
        _activeThresholds.startAngle - kShortRomTolerance) {
      _shortRomStartPending = true;
    }
  }

  @override
  void recordBilateralAngles(double? leftAngle, double? rightAngle) {
    // No-op in side view. Asymmetry is a front-only feature; the off-camera
    // arm isn't reliably trackable here.
  }

  @override
  void onRepEnd() {
    if (_eccentricStart != null) {
      _lastEccentricDuration = DateTime.now().difference(_eccentricStart!);
    }
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      _eccentricTooFastCount++;
    }
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      _concentricTooFastCount++;
    }

    // Tempo inconsistency detection (sliding-window variance).
    _lastRepTempoInconsistent = false;
    if (_tempoReArmRepsRemaining > 0) {
      _tempoReArmRepsRemaining--;
    } else if (_concentricDurations.length >= kTempoConsistencyWindow) {
      final window = _concentricDurations.sublist(
        _concentricDurations.length - kTempoConsistencyWindow,
      );
      final ms = window.map((d) => d.inMilliseconds.toDouble()).toList();
      final mean = ms.reduce((a, b) => a + b) / ms.length;
      if (mean > 0) {
        final spread =
            ms.reduce((a, b) => a > b ? a : b) -
            ms.reduce((a, b) => a < b ? a : b);
        if (spread / mean > kTempoInconsistencyRatio) {
          _lastRepTempoInconsistent = true;
          _tempoInconsistentCount++;
          _tempoReArmRepsRemaining = kTempoConsistencyReArmReps;
        }
      }
    }

    _lastRepQuality = _computeQualityScore();
    _repQualities.add(_lastRepQuality);

    _repStartSnapshot = null;
    _shortRomStartPending = false;
    _shortRomPeakPending = false;
    _concentricStart = null;
    _eccentricStart = null;
  }

  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];
    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    final useLeft = _activeArmIsLeft;

    final torsoLen = _computeTorsoLen(current, useLeft);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Forward trunk lean — side-view sagittal projection.
    //
    // Emits `depthSwing` ("Don't rock forward"). The lateral-X swing leg
    // that used to live above this block and ALSO fired `torsoSwing` was
    // deleted 2026-05-21 — in a 2D side-view camera, the user's lateral
    // axis projects into screen depth and the absolute screen-X shift of
    // the shoulder is, in practice, dominated by the same forward sagittal
    // lean this block already detects. Keeping both gave two cues for one
    // physical motion and named them "swing" while the user was actually
    // leaning.
    //
    // Dead-band: pose-estimation noise on the shoulder-hip vector is
    // ~1-2°. The effective dead-band (3° at tolerance=0, widening toward
    // `torsoLeanThresholdDeg` as the user raises the Form Tolerance
    // slider) is suppressed even if it crosses the audit threshold — a
    // real lean-cheat is 15°+, so this only blocks the degenerate
    // "threshold sits inside the noise" case that surfaced when
    // kTorsoLeanThresholdDeg was 8°.
    final baseline = _baselineTorsoAngle;
    if (baseline != null) {
      final currentAngle = _torsoAngle(current, useLeft);
      if (currentAngle != null) {
        final delta = (currentAngle - baseline).abs();
        if (delta > _maxLeanDeltaDeg) _maxLeanDeltaDeg = delta;
        if (delta > _formThresholds.effectiveLeanDeadband &&
            delta > _formThresholds.torsoLeanThresholdDeg) {
          errors.add(FormError.depthSwing);
        }
      }
    }

    // Shoulder arc — hip-pivot rotation around the vertical axis.
    //
    // Hip-pivot rotation manifests as a screen-X swing of the shoulder
    // relative to the hip. The Y component of the displacement is
    // intentionally dropped: a forward sagittal lean ALSO moves the
    // shoulder in Y (the torso pitches forward, lowering the shoulder
    // in screen space), so including it would re-introduce the lean
    // confound that already lives on the `depthSwing` detector above.
    // Pre-2026-05-21 this metric was the Euclidean magnitude
    // sqrt(dx² + dy²) / torsoLen and false-fired "Stop rotating" on a
    // pure 14°+ forward lean — see GLOSSARY and CHANGELOG.
    if (_baselineShoulderRelX != null) {
      final shoulder = current.landmark(
        useLeft ? LM.leftShoulder : LM.rightShoulder,
        minConfidence: kMinLandmarkConfidence,
      );
      final hip = current.landmark(
        useLeft ? LM.leftHip : LM.rightHip,
        minConfidence: kMinLandmarkConfidence,
      );
      if (shoulder != null && hip != null) {
        final relX = shoulder.x - hip.x;
        final dx = relX - _baselineShoulderRelX!;
        final disp = dx.abs();
        final ratio = disp / torsoLen;
        if (ratio > _maxShoulderArcRatio) _maxShoulderArcRatio = ratio;
        // Shoulder-arc shares the swing dead-band — both measure hip-relative
        // displacement and have the same noise characteristics.
        if (ratio > _formThresholds.effectiveSwingDeadband &&
            ratio > _formThresholds.swingThreshold) {
          errors.add(FormError.shoulderArc);
        }
      }
    }

    // Single-arm elbow drift — torso-perpendicular projection.
    //
    // Old metric (screen-X displacement / torsoLen) was confounded by
    // torso lean: a forward stance shifted elbow-X without any actual
    // elbow-vs-torso drift. New metric projects (E − S) onto the torso
    // perpendicular n̂ = (−u_y, u_x) where u = (S − H) / |S − H|.
    // Invariant to torso lean by construction.
    //
    // Rationale + math: docs/biceps/BICEPS_CURL_SIDE_VIEW_SPEC.md §B.
    final driftShoulder = current.landmark(
      useLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final driftHip = current.landmark(
      useLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final driftElbow = current.landmark(
      useLeft ? LM.leftElbow : LM.rightElbow,
      minConfidence: kMinLandmarkConfidence,
    );
    if (driftShoulder != null && driftHip != null && driftElbow != null) {
      final ux = driftShoulder.x - driftHip.x;
      final uy = driftShoulder.y - driftHip.y;
      final torsoVecLen = math.sqrt(ux * ux + uy * uy);
      if (torsoVecLen > 0.01) {
        final nx = -uy / torsoVecLen;
        final ny = ux / torsoVecLen;
        final perpOffset =
            (driftElbow.x - driftShoulder.x) * nx +
            (driftElbow.y - driftShoulder.y) * ny;
        final signedRatio = perpOffset / torsoVecLen;
        final ratio = signedRatio.abs();
        _lastSignedElbowDriftRatio = signedRatio;
        if (ratio > _maxDriftRatio) {
          _maxDriftRatio = ratio;
          // Capture the SIGNED ratio at the frame where the magnitude
          // peaked. Lets the retune pipeline split forward-elbow vs.
          // back-elbow cheats; without this, only the absolute peak
          // survives and the sign is lost at rep commit.
          _signedElbowDriftRatioAtMax = signedRatio;
        }
        // Sustained-drift gate: accumulate per-frame evidence, emit the
        // `elbowDrift` verdict ONCE at rep commit (see
        // `consumeCompletionErrors`). A single jittery off-line frame at
        // peak flexion — where shoulder/elbow are ML Kit's jitteriest in
        // side view because both can occlude — no longer false-fires.
        //
        // The dual-gate (dead-band AND audit threshold) is preserved
        // verbatim; it now decides whether a frame *counts as exceeding*,
        // not whether to fire the cue. Dead-band: elbow perpendicular-
        // offset noise floor sits at ~0.04-0.06; the effective dead-band
        // absorbs that and widens toward `driftThreshold` as the user
        // raises the Form Tolerance slider.
        _driftTotalEvalFrameCount++;
        if (ratio > _formThresholds.effectiveDriftDeadband &&
            ratio > _formThresholds.driftThreshold) {
          _driftExceedFrameCount++;
        }
      }
    }

    // Shoulder shrug detection.
    if (_baselineShoulderRelY != null) {
      final shoulder = current.landmark(
        useLeft ? LM.leftShoulder : LM.rightShoulder,
        minConfidence: kMinLandmarkConfidence,
      );
      final hip = current.landmark(
        useLeft ? LM.leftHip : LM.rightHip,
        minConfidence: kMinLandmarkConfidence,
      );
      if (shoulder != null && hip != null) {
        final relY = shoulder.y - hip.y;
        final dy = relY - _baselineShoulderRelY!;
        // Shrug is shoulder moving UP (smaller y). relY becomes more negative.
        final shrugValue = -dy; // positive = moving up
        final ratio = shrugValue / torsoLen;
        if (ratio > _maxShrugRatio) _maxShrugRatio = ratio;
        // Dead-band: natural scapular elevation during peak elbow flexion
        // (3-4 cm on a ~50 cm torso) sits at ratio ~0.06-0.08. The 0.06
        // baseline dead-band silences this baseline activity; the 0.20
        // audit threshold catches real "shoulders to ears" cheats. The
        // tolerance slider widens the silent budget toward `shrugThreshold`.
        if (ratio > _formThresholds.effectiveShrugDeadband &&
            ratio > _formThresholds.shrugThreshold) {
          errors.add(FormError.shoulderShrug);
        }
      }
    }

    // Back lean (hyperextension) detection.
    if (_baselineTorsoAngleSigned != null && _facingRight != null) {
      final currentAngleSigned = _torsoAngleSigned(current, useLeft);
      if (currentAngleSigned != null) {
        final delta = currentAngleSigned - _baselineTorsoAngleSigned!;
        // Facing right: backward lean is shoulder moving LEFT (x decreases) -> delta negative.
        // Facing left: backward lean is shoulder moving RIGHT (x increases) -> delta positive.
        final backLeanDeg = _facingRight! ? -delta : delta;
        if (backLeanDeg > _maxBackLeanDeg) _maxBackLeanDeg = backLeanDeg;
        // Back-lean shares the lean baseline dead-band — same pose-noise
        // floor on the torso vector. With backLeanThresholdDeg back at
        // 10°, the dead-band mostly enforces non-negativity gating (back
        // lean can read 1-2° negative on jittery frames even with no real
        // backward tilt). Note `effectiveBackLeanDeadband` uses the same
        // baseline as forward lean but interpolates against the *back*
        // lean threshold, so the two cues reach different effective
        // values at tolerance=100.
        if (backLeanDeg > _formThresholds.effectiveBackLeanDeadband &&
            backLeanDeg > _formThresholds.backLeanThresholdDeg) {
          errors.add(FormError.backLean);
        }
      }
    }

    return errors;
  }

  @override
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];

    if (_shortRomPeakPending) {
      errors.add(FormError.shortRomPeak);
      _shortRomPeakPending = false;
    } else if (_shortRomStartPending) {
      errors.add(FormError.shortRomStart);
      _shortRomStartPending = false;
    }

    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      errors.add(FormError.eccentricTooFast);
    }
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      errors.add(FormError.concentricTooFast);
    }
    if (_lastRepTempoInconsistent) {
      errors.add(FormError.tempoInconsistent);
    }

    // Fatigue.
    if (!_fatigueFired && _concentricDurations.length >= kFatigueMinReps) {
      final firstAvg = _avgDuration(
        _concentricDurations.sublist(0, kFatigueWindowSize),
      );
      final lastAvg = _avgDuration(
        _concentricDurations.sublist(
          _concentricDurations.length - kFatigueWindowSize,
        ),
      );
      final historicalMedian = _historicalMedianMs();
      final baseline = math.max(firstAvg, historicalMedian);
      if (baseline > 0 && lastAvg / baseline > kFatigueSlowdownRatio) {
        errors.add(FormError.fatigue);
        _fatigueFired = true;
      }
    }

    // Sustained elbow-drift verdict. `elbowDrift` was a per-frame error
    // until 2026-05-16; it now joins the other per-rep verdicts here. Emit
    // ONCE per rep iff a meaningful fraction of the rep's evaluated frames
    // held the elbow off the torso line. Fails OPEN below the min-frame
    // floor (mirrors the squat sustained-lean gate and curl's other
    // fail-open per-rep checks) — a too-short rep can't carry enough
    // signal to grade, so it's silently passed rather than false-flagged.
    if (_driftTotalEvalFrameCount >= kDriftMinEvalFrames &&
        _driftExceedFrameCount / _driftTotalEvalFrameCount >=
            kDriftSustainedFraction) {
      errors.add(FormError.elbowDrift);
    }
    // Drain the per-rep counters at the commit boundary (mirrors squat's
    // two-reset-site pattern: `onDescendingStart` + commit). The host
    // reads quality/telemetry getters post-commit, but those anchor on
    // `_maxDriftRatio`, not these counters, so zeroing here is safe.
    _driftExceedFrameCount = 0;
    _driftTotalEvalFrameCount = 0;

    return errors;
  }

  @override
  void reset() {
    _repStartSnapshot = null;
    _shortRomStartPending = false;
    _shortRomPeakPending = false;
    _activeThresholds = RomThresholds.global();
    _view = CurlCameraView.sideLeft;
    _concentricStart = null;
    _eccentricStart = null;
    _lastEccentricDuration = null;
    _lastConcentricDuration = null;
    _concentricDurations.clear();
    _fatigueFired = false;
    _maxDriftRatio = 0.0;
    _maxLeanDeltaDeg = 0.0;
    _maxShoulderArcRatio = 0.0;
    _maxShrugRatio = 0.0;
    _maxBackLeanDeg = 0.0;
    _lastSignedElbowDriftRatio = null;
    _signedElbowDriftRatioAtMax = null;
    _driftExceedFrameCount = 0;
    _driftTotalEvalFrameCount = 0;
    _baselineTorsoAngle = null;
    _baselineTorsoAngleSigned = null;
    _baselineShoulderRelX = null;
    _baselineShoulderRelY = null;
    _facingRight = null;
    _leftArmConfSum = 0.0;
    _rightArmConfSum = 0.0;
    _lastRepQuality = 1.0;
    _repQualities.clear();
    _eccentricTooFastCount = 0;
    _concentricTooFastCount = 0;
    _tempoInconsistentCount = 0;
    _tempoReArmRepsRemaining = 0;
    _lastRepTempoInconsistent = false;
  }

  // ── Public read-only state ───────────────────────────
  @override
  double get lastRepQuality => _lastRepQuality;

  @override
  double get averageQuality {
    if (_repQualities.isEmpty) return 1.0;
    return _repQualities.reduce((a, b) => a + b) / _repQualities.length;
  }

  @override
  List<double> get repQualities => List.unmodifiable(_repQualities);

  @override
  bool get fatigueDetected => _fatigueFired;

  @override
  int get eccentricTooFastCount => _eccentricTooFastCount;

  @override
  int get concentricTooFastCount => _concentricTooFastCount;

  @override
  int get tempoInconsistentCount => _tempoInconsistentCount;

  @override
  Duration? get lastConcentricDuration => _lastConcentricDuration;

  /// Most recent signed perpendicular elbow-offset ratio. Sign convention:
  /// positive = elbow on the side of n̂ where n̂ = (−u_y, u_x) and
  /// u = (S − H) / |S − H|. Null when landmarks are missing or torso
  /// length collapsed. Resets at rep boundary.
  @override
  double? get lastSignedElbowDriftRatio => _lastSignedElbowDriftRatio;

  /// Signed elbow-drift ratio captured at the frame where the absolute
  /// magnitude peaked this rep. Positive sign uses the same `n̂` convention
  /// as [lastSignedElbowDriftRatio]. Null until the elbow path runs at
  /// least once with valid landmarks. Persisted as
  /// `biceps_elbow_drift_signed` (schema v5) so the retune pipeline can
  /// distinguish forward-elbow cheats from back-elbow cheats.
  @override
  double? get signedElbowDriftRatioAtMax => _signedElbowDriftRatioAtMax;

  /// Max absolute elbow-drift ratio observed during the current rep.
  /// Telemetry-only; the flag uses the same value compared to
  /// [kDriftThreshold]. Cleared on rep boundary.
  @override
  double get maxElbowDriftRatioThisRep => _maxDriftRatio;

  /// Max torso-lean delta in degrees observed during the current rep.
  @override
  double get maxTorsoLeanDegThisRep => _maxLeanDeltaDeg;

  /// Max shoulder-arc-displacement ratio observed during the current rep.
  @override
  double get maxShoulderDriftRatioThisRep => _maxShoulderArcRatio;

  /// Max back-lean (hyperextension) degrees observed during the current rep.
  @override
  double get maxBackLeanDegThisRep => _maxBackLeanDeg;

  /// Max shoulder-shrug ratio observed during the current rep.
  /// Telemetry-only; the flag uses the same value compared to
  /// [kShrugThreshold]. Cleared on rep boundary.
  @override
  double get maxShrugRatioThisRep => _maxShrugRatio;

  /// Anatomical arm the analyzer locked onto for the most recent rep.
  /// Resolved at [onRepStart] from per-arm landmark-confidence sums and
  /// frozen for the rep. Read by `CurlStrategy._commitRepSamples` so the
  /// `side=` token in `rep.extremes` reflects the arm actually measured.
  @override
  bool get activeArmIsLeftThisRep => _activeArmIsLeft;

  /// Summed left-arm landmark confidences captured at the most recent
  /// [onRepStart]. Telemetry-only — exposes the input to
  /// [_resolveActiveArm].
  @override
  double get leftArmConfidenceSumThisRep => _leftArmConfSum;

  /// Summed right-arm landmark confidences captured at the most recent
  /// [onRepStart]. Telemetry-only — counterpart to
  /// [leftArmConfidenceSumThisRep].
  @override
  double get rightArmConfidenceSumThisRep => _rightArmConfSum;

  /// Facing direction detected at the most recent [onRepStart]. Surfaces
  /// the analyzer's `_facingRight` to the strategy so the rep-commit
  /// telemetry can show whether the pose-detected facing agrees with
  /// the user's home-screen declared side.
  @override
  bool? get facingRightThisRep => _facingRight;

  // ─────────────────────────────────────────────────────
  // Internals
  // ─────────────────────────────────────────────────────

  double _computeQualityScore() {
    var score = 1.0;
    final ft = _formThresholds;

    // The lateral-X swing deduction (`_maxSwingRatio`) was removed 2026-05-21
    // when the lateral leg of `torsoSwing` was deleted from the side analyzer.
    // The lean leg below — now firing as `depthSwing` — already deducts for
    // the same physical motion the deleted leg also fired on, so this is a
    // double-count removal, not an unpunished cheat.
    if (_maxLeanDeltaDeg > ft.torsoLeanThresholdDeg) {
      final severity =
          ((_maxLeanDeltaDeg - ft.torsoLeanThresholdDeg) /
                  ft.torsoLeanThresholdDeg)
              .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }
    if (_maxShoulderArcRatio > ft.swingThreshold) {
      final severity =
          ((_maxShoulderArcRatio - ft.swingThreshold) / ft.swingThreshold)
              .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }
    if (_maxDriftRatio > ft.driftThreshold) {
      final severity =
          ((_maxDriftRatio - ft.driftThreshold) / ft.driftThreshold).clamp(
            0.0,
            1.0,
          );
      score -= severity * kQualityDriftMaxDeduction;
    }
    if (_maxShrugRatio > ft.shrugThreshold) {
      final severity =
          ((_maxShrugRatio - ft.shrugThreshold) / ft.shrugThreshold).clamp(
            0.0,
            1.0,
          );
      score -= severity * kQualityShrugMaxDeduction;
    }
    if (_maxBackLeanDeg > ft.backLeanThresholdDeg) {
      final severity =
          ((_maxBackLeanDeg - ft.backLeanThresholdDeg) /
                  ft.backLeanThresholdDeg)
              .clamp(0.0, 1.0);
      score -= severity * kQualityBackLeanMaxDeduction;
    }
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      score -= kQualityEccentricDeduction;
    }
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      score -= kQualityConcentricDeduction;
    }
    if (_lastRepTempoInconsistent) {
      score -= kQualityTempoInconsistencyDeduction;
    }
    if (_shortRomStartPending || _shortRomPeakPending) {
      score -= kQualityShortRomDeduction;
    }

    return score.clamp(0.0, 1.0);
  }

  double _avgDuration(List<Duration> durations) {
    if (durations.isEmpty) return 0;
    final totalMs = durations.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return totalMs / durations.length;
  }

  double _historicalMedianMs() {
    if (_historicalConcentricDurations.isEmpty) return 0.0;
    final sorted =
        _historicalConcentricDurations.map((d) => d.inMilliseconds).toList()
          ..sort();
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2].toDouble();
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
  }

  /// Torso angle from vertical for the visible side. Returns null when
  /// either landmark is missing or below confidence.
  double? _torsoAngle(PoseResult pose, bool useLeft) {
    final shoulder = pose.landmark(
      useLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = pose.landmark(
      useLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    return angleToVertical(shoulder, hip);
  }

  /// Signed torso angle from vertical.
  double? _torsoAngleSigned(PoseResult pose, bool useLeft) {
    final shoulder = pose.landmark(
      useLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = pose.landmark(
      useLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    return signedAngleToVertical(shoulder, hip);
  }

  /// Detect if the user is facing right (X increasing) by comparing nose to shoulder.
  bool? _detectFacingRight(PoseResult pose, bool useLeft) {
    final shoulder = pose.landmark(
      useLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final nose = pose.landmark(LM.nose, minConfidence: kMinLandmarkConfidence);
    if (shoulder == null || nose == null) return null;
    return nose.x > shoulder.x;
  }

  /// Resolve which anatomical arm is most likely the visible one in this
  /// pose. Sums the (raw, pre-confidence-gate) confidences for the
  /// shoulder + hip + elbow trio on each side and picks the larger.
  /// Falls back to the declared [_view] hint when both totals are
  /// effectively zero (no landmarks at all).
  ///
  /// Why summing pre-gate confidences: the standard `landmark()` lookup
  /// returns null below `kMinLandmarkConfidence`, but here we need a
  /// graceful tiebreaker even when both arms are partially visible.
  /// Reading the underlying confidences lets us still pick the better
  /// arm when neither passes the strict gate.
  bool _resolveActiveArm(PoseResult pose) {
    double conf(int type) {
      // Walk the landmark list directly so we see confidences below
      // `kMinLandmarkConfidence`. `pose.landmark(...)` would return null
      // for those and force a hard hint-fallback in too many cases.
      for (final lm in pose.landmarks) {
        if (lm.type == type) return lm.confidence;
      }
      return 0.0;
    }

    final leftTotal =
        conf(LM.leftShoulder) + conf(LM.leftHip) + conf(LM.leftElbow);
    final rightTotal =
        conf(LM.rightShoulder) + conf(LM.rightHip) + conf(LM.rightElbow);
    // Snapshot for telemetry. Both branches below capture the same numbers
    // so the rep-commit logger always has the input that drove the decision.
    _leftArmConfSum = leftTotal;
    _rightArmConfSum = rightTotal;
    if (leftTotal == 0 && rightTotal == 0) {
      // No landmarks at all — fall back to the declared hint.
      return _view != CurlCameraView.sideRight;
    }
    return leftTotal >= rightTotal;
  }

  double? _computeTorsoLen(PoseResult current, bool useLeft) {
    if (useLeft) {
      return verticalDist(
        current.landmark(
          LM.leftShoulder,
          minConfidence: kMinLandmarkConfidence,
        ),
        current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
      );
    }
    return verticalDist(
      current.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
      current.landmark(LM.rightHip, minConfidence: kMinLandmarkConfidence),
    );
  }
}
