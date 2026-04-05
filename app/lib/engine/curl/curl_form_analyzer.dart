import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';

/// Form analyzer for biceps curl — view-aware.
///
/// Frame-level errors (evaluated every frame during CONCENTRIC/ECCENTRIC):
///   - Torso swing: ΔX_shoulder / L_torso > kSwingThreshold
///   - Elbow drift: ΔX_elbow / L_torso > kDriftThreshold
///
/// Rep-boundary errors (evaluated once per rep completion/abort):
///   - Short ROM: rep started but never reached PEAK
///   - Eccentric too fast: eccentric phase < kMinEccentricSec
///   - Lateral asymmetry: left/right peak angle delta > threshold for N reps
///   - Fatigue: concentric duration degrading across reps
///
/// Per-rep quality score: 0.0–1.0, deductions proportional to error magnitude.
class CurlFormAnalyzer {
  PoseResult? _repStartSnapshot;
  bool _shortRomPending = false;
  CurlCameraView _view = CurlCameraView.unknown;

  // ── Tempo tracking ──────────────────────────────────────
  DateTime? _concentricStart;
  DateTime? _eccentricStart;
  Duration? _lastEccentricDuration;

  // ── Fatigue detection ───────────────────────────────────
  final List<Duration> _concentricDurations = [];
  bool _fatigueFired = false;

  // ── Bilateral asymmetry (front view only) ───────────────
  final List<double> _asymmetryDeltas = [];
  int _consecutiveAsymmetricReps = 0;

  // ── Tempo tracking ──────────────────────────────────────
  int _eccentricTooFastCount = 0;

  // ── Per-rep quality score ───────────────────────────────
  double _maxSwingRatio = 0.0;
  double _maxDriftRatio = 0.0;
  double _lastRepQuality = 1.0;
  final List<double> _repQualities = [];

  /// Set once after view detection locks (called by RepCounter).
  void setView(CurlCameraView view) => _view = view;

  /// Call at IDLE -> CONCENTRIC.
  void onRepStart(PoseResult snapshot) {
    _repStartSnapshot = snapshot;
    _shortRomPending = false;
    _concentricStart = DateTime.now();
    _eccentricStart = null;
    _lastEccentricDuration = null;
    _maxSwingRatio = 0.0;
    _maxDriftRatio = 0.0;
  }

  /// Call at CONCENTRIC -> PEAK.
  void onPeakReached() {
    // Concentric duration = now - concentricStart.
    if (_concentricStart != null) {
      _concentricDurations.add(DateTime.now().difference(_concentricStart!));
    }
  }

  /// Call at PEAK -> ECCENTRIC.
  void onEccentricStart() {
    _eccentricStart = DateTime.now();
  }

  /// Call when CONCENTRIC -> IDLE without reaching PEAK (abandoned rep).
  void onAbortedRep() {
    _shortRomPending = true;
  }

  /// Record bilateral peak angles at rep completion (front view only).
  void recordBilateralAngles(double? leftAngle, double? rightAngle) {
    if (_view != CurlCameraView.front) return;
    if (leftAngle == null || rightAngle == null) return;
    _asymmetryDeltas.add((leftAngle - rightAngle).abs());
  }

  /// Call at the end of each completed rep to finalize quality and clear state.
  void onRepEnd() {
    // Compute eccentric duration.
    if (_eccentricStart != null) {
      _lastEccentricDuration = DateTime.now().difference(_eccentricStart!);
    }

    // Track eccentric too fast.
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      _eccentricTooFastCount++;
    }

    // Compute quality score.
    _lastRepQuality = _computeQualityScore();
    _repQualities.add(_lastRepQuality);

    _repStartSnapshot = null;
    _shortRomPending = false;
    _concentricStart = null;
    _eccentricStart = null;
  }

  /// Frame-level evaluation — returns torsoSwing / elbowDrift if active.
  /// Also tracks max deduction magnitudes for quality scoring.
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];
    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    final useLeft  = _view != CurlCameraView.sideRight;
    final useRight = _view != CurlCameraView.sideLeft;

    final torsoLen = _computeTorsoLen(current, useLeft, useRight);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Torso swing.
    final swing = (useLeft  ? horizontalShift(ref, current, LM.leftShoulder)  : null)
               ?? (useRight ? horizontalShift(ref, current, LM.rightShoulder) : null);
    if (swing != null) {
      final ratio = swing / torsoLen;
      if (ratio > _maxSwingRatio) _maxSwingRatio = ratio;
      if (ratio > kSwingThreshold) errors.add(FormError.torsoSwing);
    }

    // Elbow drift.
    final drift = (useLeft  ? horizontalShift(ref, current, LM.leftElbow)  : null)
               ?? (useRight ? horizontalShift(ref, current, LM.rightElbow) : null);
    if (drift != null) {
      final ratio = drift / torsoLen;
      if (ratio > _maxDriftRatio) _maxDriftRatio = ratio;
      if (ratio > kDriftThreshold) errors.add(FormError.elbowDrift);
    }

    return errors;
  }

  /// Rep-boundary evaluation — drains one-shot errors.
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];

    if (_shortRomPending) {
      errors.add(FormError.shortRom);
      _shortRomPending = false;
    }

    // Eccentric too fast.
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      errors.add(FormError.eccentricTooFast);
    }

    // Bilateral asymmetry (front view, rolling check).
    if (_asymmetryDeltas.isNotEmpty) {
      final lastDelta = _asymmetryDeltas.last;
      if (lastDelta > kAsymmetryAngleDelta) {
        _consecutiveAsymmetricReps++;
      } else {
        _consecutiveAsymmetricReps = 0;
      }
      if (_consecutiveAsymmetricReps >= kAsymmetryConsecutiveReps) {
        errors.add(FormError.lateralAsymmetry);
      }
    }

    // Fatigue detection.
    if (!_fatigueFired && _concentricDurations.length >= kFatigueMinReps) {
      final firstAvg = _avgDuration(_concentricDurations.sublist(0, kFatigueWindowSize));
      final lastAvg = _avgDuration(_concentricDurations.sublist(
          _concentricDurations.length - kFatigueWindowSize));
      if (firstAvg > 0 && lastAvg / firstAvg > kFatigueSlowdownRatio) {
        errors.add(FormError.fatigue);
        _fatigueFired = true;
      }
    }

    return errors;
  }

  /// Last completed rep's quality score (0.0–1.0).
  double get lastRepQuality => _lastRepQuality;

  /// Average quality across all completed reps.
  double get averageQuality {
    if (_repQualities.isEmpty) return 1.0;
    return _repQualities.reduce((a, b) => a + b) / _repQualities.length;
  }

  /// Per-rep quality scores for all completed reps (0.0–1.0 each).
  List<double> get repQualities => List.unmodifiable(_repQualities);

  /// Whether fatigue was detected at any point in this session.
  bool get fatigueDetected => _fatigueFired;

  /// Number of reps where the eccentric (lowering) phase was too fast.
  int get eccentricTooFastCount => _eccentricTooFastCount;

  void reset() {
    _repStartSnapshot = null;
    _shortRomPending = false;
    _view = CurlCameraView.unknown;
    _concentricStart = null;
    _eccentricStart = null;
    _lastEccentricDuration = null;
    _concentricDurations.clear();
    _fatigueFired = false;
    _asymmetryDeltas.clear();
    _consecutiveAsymmetricReps = 0;
    _maxSwingRatio = 0.0;
    _maxDriftRatio = 0.0;
    _lastRepQuality = 1.0;
    _repQualities.clear();
    _eccentricTooFastCount = 0;
  }

  // ── Helpers ──────────────────────────────────────────

  double _computeQualityScore() {
    var score = 1.0;

    // Proportional swing deduction: scale from threshold to 2x threshold.
    if (_maxSwingRatio > kSwingThreshold) {
      final severity = ((_maxSwingRatio - kSwingThreshold) / kSwingThreshold).clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }

    // Proportional drift deduction.
    if (_maxDriftRatio > kDriftThreshold) {
      final severity = ((_maxDriftRatio - kDriftThreshold) / kDriftThreshold).clamp(0.0, 1.0);
      score -= severity * kQualityDriftMaxDeduction;
    }

    // Rushed eccentric.
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      score -= kQualityEccentricDeduction;
    }

    // Short ROM.
    if (_shortRomPending) {
      score -= kQualityShortRomDeduction;
    }

    // Asymmetry (front view).
    if (_asymmetryDeltas.isNotEmpty && _asymmetryDeltas.last > kAsymmetryAngleDelta) {
      score -= kQualityAsymmetryDeduction;
    }

    return score.clamp(0.0, 1.0);
  }

  double _avgDuration(List<Duration> durations) {
    if (durations.isEmpty) return 0;
    final totalMs = durations.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return totalMs / durations.length;
  }

  double? _computeTorsoLen(PoseResult current, bool useLeft, bool useRight) {
    final l = useLeft
        ? verticalDist(
            current.landmark(LM.leftShoulder, minConfidence: kMinLandmarkConfidence),
            current.landmark(LM.leftHip,      minConfidence: kMinLandmarkConfidence),
          )
        : null;
    final r = useRight
        ? verticalDist(
            current.landmark(LM.rightShoulder, minConfidence: kMinLandmarkConfidence),
            current.landmark(LM.rightHip,      minConfidence: kMinLandmarkConfidence),
          )
        : null;
    if (l != null && r != null) return (l + r) / 2.0;
    return l ?? r;
  }
}
