import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';
import 'curl_form_analyzer_extras.dart';
import 'dtw_scorer.dart';

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
///   - `torsoSwing`: lateral X-shift OR forward trunk-lean angle delta
///     above [kTorsoLeanThresholdDeg]. Combined into one cue because the
///     user experiences both as "torso momentum cheat."
///   - `shoulderArc`: hip-pivot rotation — 2D shoulder displacement in
///     hip-relative coordinates / torso length > [kSwingThreshold].
///   - `elbowDrift`: torso-perpendicular projection of the elbow offset
///     `(E − S) · n̂ / |S − H|` — magnitude > [kDriftThreshold]. Lean-invariant
///     by construction; sign is preserved on `lastSignedElbowDriftRatio` for
///     telemetry. See `docs/biceps/BICEPS_CURL_SIDE_VIEW_SPEC.md §B`.
///
/// Rep-boundary errors:
///   - `shortRomStart`, `shortRomPeak`: classified against active thresholds.
///   - `eccentricTooFast`, `concentricTooFast`, `tempoInconsistent`: tempo.
///   - `fatigue`: concentric slowdown over the session.
///
/// Features intentionally NOT present (front-only):
///   - Bilateral asymmetry — only one arm visible in side view.
///   - Depth-swing — apparent torso length doesn't change usefully when
///     the user is already side-on; the cheat axis is sagittal lean,
///     which the trunk-lean angle check covers.
class CurlSideFormAnalyzer extends CurlAnalyzer {
  CurlSideFormAnalyzer({
    List<Duration> historicalConcentricDurations = const [],
    List<double>? referenceRepAngleSeries,
    bool enableDtwScoring = false,
    DtwScorer? dtwScorer,
  }) : _historicalConcentricDurations = List<Duration>.unmodifiable(
         historicalConcentricDurations,
       ),
       _referenceRepAngleSeries = referenceRepAngleSeries,
       _enableDtwScoring = enableDtwScoring,
       _dtwScorer = dtwScorer ?? DtwScorer();

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

  // ── DTW ──────────────────────────────────────────────
  final List<double>? _referenceRepAngleSeries;
  final bool _enableDtwScoring;
  final DtwScorer _dtwScorer;

  // ── Per-rep extremes for quality scoring ─────────────
  double _maxSwingRatio = 0.0;
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

  // ── Side-view baselines (snapshot at rep start) ──────
  double? _baselineTorsoAngle;
  double? _baselineTorsoAngleSigned;
  double? _baselineShoulderRelX;
  double? _baselineShoulderRelY;
  bool? _facingRight;

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
    _maxSwingRatio = 0.0;
    _maxDriftRatio = 0.0;
    _maxLeanDeltaDeg = 0.0;
    _maxShoulderArcRatio = 0.0;
    _maxShrugRatio = 0.0;
    _maxBackLeanDeg = 0.0;
    _lastSignedElbowDriftRatio = null;
    _signedElbowDriftRatioAtMax = null;
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
    final useRight = !useLeft;

    final torsoLen = _computeTorsoLen(current, useLeft, useRight);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Lateral torso swing — check whichever shoulder is visible.
    final swing = useLeft
        ? horizontalShift(ref, current, LM.leftShoulder)
        : horizontalShift(ref, current, LM.rightShoulder);
    if (swing != null) {
      final ratio = swing / torsoLen;
      if (ratio > _maxSwingRatio) _maxSwingRatio = ratio;
      if (ratio > kSwingThreshold) errors.add(FormError.torsoSwing);
    }

    // Forward trunk lean angle — side-view sagittal projection.
    final baseline = _baselineTorsoAngle;
    if (baseline != null) {
      final currentAngle = _torsoAngle(current, useLeft);
      if (currentAngle != null) {
        final delta = (currentAngle - baseline).abs();
        if (delta > _maxLeanDeltaDeg) _maxLeanDeltaDeg = delta;
        if (delta > kTorsoLeanThresholdDeg &&
            !errors.contains(FormError.torsoSwing)) {
          errors.add(FormError.torsoSwing);
        }
      }
    }

    // Shoulder arc — hip-pivot rotation, hip-relative coordinates.
    if (_baselineShoulderRelX != null && _baselineShoulderRelY != null) {
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
        final relY = shoulder.y - hip.y;
        final dx = relX - _baselineShoulderRelX!;
        final dy = relY - _baselineShoulderRelY!;
        final disp = math.sqrt(dx * dx + dy * dy);
        final ratio = disp / torsoLen;
        if (ratio > _maxShoulderArcRatio) _maxShoulderArcRatio = ratio;
        if (ratio > kSwingThreshold) errors.add(FormError.shoulderArc);
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
        if (ratio > kDriftThreshold) errors.add(FormError.elbowDrift);
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
        if (ratio > kShrugThreshold) errors.add(FormError.shoulderShrug);
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
        if (backLeanDeg > kBackLeanThresholdDeg) {
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
    _maxSwingRatio = 0.0;
    _maxDriftRatio = 0.0;
    _maxLeanDeltaDeg = 0.0;
    _maxShoulderArcRatio = 0.0;
    _maxShrugRatio = 0.0;
    _maxBackLeanDeg = 0.0;
    _lastSignedElbowDriftRatio = null;
    _signedElbowDriftRatioAtMax = null;
    _baselineTorsoAngle = null;
    _baselineTorsoAngleSigned = null;
    _baselineShoulderRelX = null;
    _baselineShoulderRelY = null;
    _facingRight = null;
    _lastRepQuality = 1.0;
    _repQualities.clear();
    _eccentricTooFastCount = 0;
    _concentricTooFastCount = 0;
    _tempoInconsistentCount = 0;
    _tempoReArmRepsRemaining = 0;
    _lastRepTempoInconsistent = false;
  }

  @override
  DtwScore? scoreRep(List<double> candidate) {
    if (!_enableDtwScoring || _referenceRepAngleSeries == null) return null;
    return _dtwScorer.score(candidate, _referenceRepAngleSeries);
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

  // ─────────────────────────────────────────────────────
  // Internals
  // ─────────────────────────────────────────────────────

  double _computeQualityScore() {
    var score = 1.0;

    if (_maxSwingRatio > kSwingThreshold) {
      final severity = ((_maxSwingRatio - kSwingThreshold) / kSwingThreshold)
          .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }
    if (_maxLeanDeltaDeg > kTorsoLeanThresholdDeg) {
      final severity =
          ((_maxLeanDeltaDeg - kTorsoLeanThresholdDeg) / kTorsoLeanThresholdDeg)
              .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }
    if (_maxShoulderArcRatio > kSwingThreshold) {
      final severity =
          ((_maxShoulderArcRatio - kSwingThreshold) / kSwingThreshold).clamp(
            0.0,
            1.0,
          );
      score -= severity * kQualitySwingMaxDeduction;
    }
    if (_maxDriftRatio > kDriftThreshold) {
      final severity = ((_maxDriftRatio - kDriftThreshold) / kDriftThreshold)
          .clamp(0.0, 1.0);
      score -= severity * kQualityDriftMaxDeduction;
    }
    if (_maxShrugRatio > kShrugThreshold) {
      final severity = ((_maxShrugRatio - kShrugThreshold) / kShrugThreshold)
          .clamp(0.0, 1.0);
      score -= severity * kQualityShrugMaxDeduction;
    }
    if (_maxBackLeanDeg > kBackLeanThresholdDeg) {
      final severity =
          ((_maxBackLeanDeg - kBackLeanThresholdDeg) / kBackLeanThresholdDeg)
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
    if (leftTotal == 0 && rightTotal == 0) {
      // No landmarks at all — fall back to the declared hint.
      return _view != CurlCameraView.sideRight;
    }
    return leftTotal >= rightTotal;
  }

  double? _computeTorsoLen(PoseResult current, bool useLeft, bool useRight) {
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
