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
class CurlFormAnalyzer extends FormAnalyzerBase with CurlFormAnalyzerExtras {
  PoseResult? _repStartSnapshot;

  /// Directional short-ROM pending flags. Classification happens in
  /// `onAbortedRep(...)` against the active thresholds set via
  /// `setActiveThresholds(...)`. Only one of these is ever true at a time
  /// (peak wins — a rep that didn't reach peak clearly missed the top half).
  bool _shortRomStartPending = false;
  bool _shortRomPeakPending = false;

  CurlCameraView _view = CurlCameraView.unknown;

  /// FSM thresholds in use for the current rep. Pushed by `RepCounter` at the
  /// IDLE → CONCENTRIC promotion site (same place the FSM promotes its own
  /// source). Used by `onAbortedRep` to classify the shortfall direction.
  ///
  /// Defaults to `RomThresholds.global()` so the analyzer still functions if
  /// the host forgets to call `setActiveThresholds` (tests, early boot).
  RomThresholds _activeThresholds = RomThresholds.global();

  // ── Tempo tracking ──────────────────────────────────────
  DateTime? _concentricStart;
  DateTime? _eccentricStart;
  Duration? _lastEccentricDuration;

  // ── Fatigue detection ───────────────────────────────────
  final List<Duration> _concentricDurations = [];
  bool _fatigueFired = false;

  /// 30-day historical concentric durations from prior sessions (WP5.4).
  /// When non-empty, the fatigue rule's baseline is raised to
  /// `max(in-session firstWindowAvg, historicalMedian)` — a user whose
  /// warmup reps are artificially slow still gets fatigue detected when
  /// later reps slow below their true baseline. Empty list → analyzer
  /// behaves exactly as pre-WP5.4 (backward compat).
  final List<Duration> _historicalConcentricDurations;

  /// Optional reference angle series for DTW scoring. Null = scoring disabled.
  final List<double>? _referenceRepAngleSeries;

  /// When true and [_referenceRepAngleSeries] is non-null, [scoreRep] returns
  /// a [DtwScore]. Defaults to false so existing call sites are unchanged.
  final bool _enableDtwScoring;

  final DtwScorer _dtwScorer;

  /// Pure-Dart analyzer. Historical durations are a plain `List<Duration>` —
  /// no service import bleed into `lib/engine/`. Default to `const []` so
  /// every existing call-site (`CurlFormAnalyzer()`) compiles unchanged.
  CurlFormAnalyzer({
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

  /// Score a completed rep's angle trace against the reference.
  /// Returns null when scoring is disabled or no reference is available.
  DtwScore? scoreRep(List<double> candidate) {
    if (!_enableDtwScoring || _referenceRepAngleSeries == null) return null;
    return _dtwScorer.score(candidate, _referenceRepAngleSeries);
  }

  // ── Bilateral asymmetry (front view only) ───────────────
  /// Per-rep bilateral peak-angle readings, front view only.
  ///
  /// Records both values (not the `|delta|`) so the sign of `left − right`
  /// survives into classification — a lagging arm has a *higher* min angle
  /// (it didn't flex as deeply). Keeping the abs delta would lose that
  /// direction and force us back to a generic "even out both arms" cue.
  final List<({double left, double right})> _asymmetryDeltas = [];
  int _consecutiveAsymmetricReps = 0;

  // ── Tempo tracking ──────────────────────────────────────
  int _eccentricTooFastCount = 0;
  int _concentricTooFastCount = 0;
  int _tempoInconsistentCount = 0;
  Duration? _lastConcentricDuration;

  // ── Tempo consistency (re-arm window, NOT permanent one-shot) ──
  /// Remaining reps to suppress re-emission of `tempoInconsistent` after firing.
  /// Unlike `_fatigueFired`, this decays — tempo drift is recoverable.
  int _tempoReArmRepsRemaining = 0;
  bool _lastRepTempoInconsistent = false;

  // ── Per-rep quality score ───────────────────────────────
  double _maxSwingRatio = 0.0;
  double _maxDriftRatio = 0.0;
  double _lastRepQuality = 1.0;
  final List<double> _repQualities = [];

  /// Set once after view detection locks (called by RepCounter).
  @override
  void setView(CurlCameraView view) => _view = view;

  /// Call at IDLE -> CONCENTRIC.
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
  }

  /// Call at CONCENTRIC -> PEAK.
  @override
  void onPeakReached() {
    // Concentric duration = now - concentricStart.
    if (_concentricStart != null) {
      final d = DateTime.now().difference(_concentricStart!);
      _concentricDurations.add(d);
      _lastConcentricDuration = d;
    }
  }

  /// Call at PEAK -> ECCENTRIC.
  @override
  void onEccentricStart() {
    _eccentricStart = DateTime.now();
  }

  /// Sets the FSM thresholds in use for the next / current rep. Called by
  /// `RepCounter` at the IDLE → CONCENTRIC promotion site so short-ROM
  /// classification in `onAbortedRep` uses the same thresholds the FSM is
  /// gating against. If never called, falls back to `RomThresholds.global()`.
  @override
  void setActiveThresholds(RomThresholds thresholds) {
    _activeThresholds = thresholds;
  }

  /// Call when CONCENTRIC -> IDLE without reaching PEAK (abandoned rep).
  ///
  /// Classifies the shortfall direction against `_activeThresholds`:
  /// - `shortRomPeak` when `minAngleReached > peakAngle + kShortRomTolerance`
  ///   (user aborted before clearing the peak gate). Takes precedence — a
  ///   rep that didn't reach peak necessarily also didn't reach full curl.
  /// - `shortRomStart` when the peak test passes but
  ///   `maxAngleAtStart < startAngle − kShortRomTolerance` (user began the
  ///   rep from partial extension, not a full-arm reset).
  /// - Neither when both extremes are within tolerance.
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

  /// Record bilateral peak angles at rep completion (front view only).
  @override
  void recordBilateralAngles(double? leftAngle, double? rightAngle) {
    if (_view != CurlCameraView.front) return;
    if (leftAngle == null || rightAngle == null) return;
    _asymmetryDeltas.add((left: leftAngle, right: rightAngle));
  }

  /// Call at the end of each completed rep to finalize quality and clear state.
  @override
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

    // Track concentric too fast.
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      _concentricTooFastCount++;
    }

    // Decide tempo inconsistency BEFORE quality score so the deduction can apply
    // on the same rep. Re-arm countdown is consumed here (per rep), and emission
    // is gated in consumeCompletionErrors by the resulting flag.
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

    // Compute quality score.
    _lastRepQuality = _computeQualityScore();
    _repQualities.add(_lastRepQuality);

    _repStartSnapshot = null;
    _shortRomStartPending = false;
    _shortRomPeakPending = false;
    _concentricStart = null;
    _eccentricStart = null;
  }

  /// Frame-level evaluation — returns torsoSwing / elbowDrift if active.
  /// Also tracks max deduction magnitudes for quality scoring.
  @override
  List<FormError> evaluate(PoseResult current) {
    final errors = <FormError>[];
    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    final useLeft = _view != CurlCameraView.sideRight;
    final useRight = _view != CurlCameraView.sideLeft;

    final torsoLen = _computeTorsoLen(current, useLeft, useRight);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Torso swing.
    final swing =
        (useLeft ? horizontalShift(ref, current, LM.leftShoulder) : null) ??
        (useRight ? horizontalShift(ref, current, LM.rightShoulder) : null);
    if (swing != null) {
      final ratio = swing / torsoLen;
      if (ratio > _maxSwingRatio) _maxSwingRatio = ratio;
      if (ratio > kSwingThreshold) errors.add(FormError.torsoSwing);
    }

    // Elbow drift.
    final drift =
        (useLeft ? horizontalShift(ref, current, LM.leftElbow) : null) ??
        (useRight ? horizontalShift(ref, current, LM.rightElbow) : null);
    if (drift != null) {
      final ratio = drift / torsoLen;
      if (ratio > _maxDriftRatio) _maxDriftRatio = ratio;
      if (ratio > kDriftThreshold) errors.add(FormError.elbowDrift);
    }

    return errors;
  }

  /// Rep-boundary evaluation — drains one-shot errors.
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

    // Eccentric too fast.
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      errors.add(FormError.eccentricTooFast);
    }

    // Concentric too fast.
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      errors.add(FormError.concentricTooFast);
    }

    // Tempo inconsistency — flag computed in onRepEnd so the per-rep quality
    // deduction lines up with the emission. Here we only surface it.
    if (_lastRepTempoInconsistent) {
      errors.add(FormError.tempoInconsistent);
    }

    // Bilateral asymmetry (front view, rolling check).
    //
    // A lagging arm has a HIGHER min-angle (it didn't flex as deeply). We take
    // the sign of (left − right) to decide which side to call out; abs delta
    // gates the streak the same way as before.
    if (_asymmetryDeltas.isNotEmpty) {
      final last = _asymmetryDeltas.last;
      final signedDelta = last.left - last.right;
      if (signedDelta.abs() > kAsymmetryAngleDelta) {
        _consecutiveAsymmetricReps++;
      } else {
        _consecutiveAsymmetricReps = 0;
      }
      if (_consecutiveAsymmetricReps >= kAsymmetryConsecutiveReps) {
        errors.add(
          signedDelta > 0
              ? FormError.asymmetryLeftLag
              : FormError.asymmetryRightLag,
        );
      }
    }

    // Fatigue detection.
    //
    // Baseline = max(in-session first-window avg, 30-day historical median).
    // Empty historical list collapses the max to `firstAvg` — backward-compat
    // with pre-WP5.4 behavior. A warm-up-slow user still gets fatigue when
    // later reps slow below their true historical baseline.
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

  /// Last completed rep's quality score (0.0–1.0).
  @override
  double get lastRepQuality => _lastRepQuality;

  /// Average quality across all completed reps.
  @override
  double get averageQuality {
    if (_repQualities.isEmpty) return 1.0;
    return _repQualities.reduce((a, b) => a + b) / _repQualities.length;
  }

  /// Per-rep quality scores for all completed reps (0.0–1.0 each).
  @override
  List<double> get repQualities => List.unmodifiable(_repQualities);

  /// Whether fatigue was detected at any point in this session.
  @override
  bool get fatigueDetected => _fatigueFired;

  /// Number of reps where the eccentric (lowering) phase was too fast.
  @override
  int get eccentricTooFastCount => _eccentricTooFastCount;

  /// Number of reps where the concentric (lifting) phase was too fast.
  @override
  int get concentricTooFastCount => _concentricTooFastCount;

  /// Number of reps where tempo inconsistency was flagged this session.
  @override
  int get tempoInconsistentCount => _tempoInconsistentCount;

  @override
  void reset() {
    _repStartSnapshot = null;
    _shortRomStartPending = false;
    _shortRomPeakPending = false;
    _activeThresholds = RomThresholds.global();
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
    _concentricTooFastCount = 0;
    _tempoInconsistentCount = 0;
    _tempoReArmRepsRemaining = 0;
    _lastRepTempoInconsistent = false;
    _lastConcentricDuration = null;
  }

  // ── Helpers ──────────────────────────────────────────

  double _computeQualityScore() {
    var score = 1.0;

    // Proportional swing deduction: scale from threshold to 2x threshold.
    if (_maxSwingRatio > kSwingThreshold) {
      final severity = ((_maxSwingRatio - kSwingThreshold) / kSwingThreshold)
          .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }

    // Proportional drift deduction.
    if (_maxDriftRatio > kDriftThreshold) {
      final severity = ((_maxDriftRatio - kDriftThreshold) / kDriftThreshold)
          .clamp(0.0, 1.0);
      score -= severity * kQualityDriftMaxDeduction;
    }

    // Rushed eccentric.
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds < kMinEccentricSec * 1000) {
      score -= kQualityEccentricDeduction;
    }

    // Rushed concentric (flinging the weight).
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds < kMinConcentricSec * 1000) {
      score -= kQualityConcentricDeduction;
    }

    // Inconsistent concentric tempo over the last N reps.
    if (_lastRepTempoInconsistent) {
      score -= kQualityTempoInconsistencyDeduction;
    }

    // Short ROM — same deduction applies to both start and peak variants.
    if (_shortRomStartPending || _shortRomPeakPending) {
      score -= kQualityShortRomDeduction;
    }

    // Asymmetry (front view). Uses abs delta for deduction; direction is
    // classification-only and doesn't change the quality penalty.
    if (_asymmetryDeltas.isNotEmpty &&
        (_asymmetryDeltas.last.left - _asymmetryDeltas.last.right).abs() >
            kAsymmetryAngleDelta) {
      score -= kQualityAsymmetryDeduction;
    }

    return score.clamp(0.0, 1.0);
  }

  double _avgDuration(List<Duration> durations) {
    if (durations.isEmpty) return 0;
    final totalMs = durations.fold<int>(0, (sum, d) => sum + d.inMilliseconds);
    return totalMs / durations.length;
  }

  /// Median of the 30-day historical window in milliseconds. Returns 0.0 on
  /// empty, which collapses `max(firstAvg, historicalMedian)` to `firstAvg` —
  /// preserving pre-WP5.4 fatigue behavior for first-time curl users.
  ///
  /// Median (not mean) because a single anomalously-slow prior rep
  /// (stretching mid-set, phone interruption, etc.) would pull a mean baseline
  /// high enough to hide real fatigue on today's session.
  double _historicalMedianMs() {
    if (_historicalConcentricDurations.isEmpty) return 0.0;
    final sorted =
        _historicalConcentricDurations.map((d) => d.inMilliseconds).toList()
          ..sort();
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2].toDouble();
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
  }

  /// Most recent rep's concentric duration. Set in `onPeakReached`; null
  /// until the first rep's peak is reached this session. Consumed by
  /// `CurlStrategy._commitRepSamples` so the VM can persist per-rep
  /// `concentric_ms` (WP5.4).
  Duration? get lastConcentricDuration => _lastConcentricDuration;

  double? _computeTorsoLen(PoseResult current, bool useLeft, bool useRight) {
    final l = useLeft
        ? verticalDist(
            current.landmark(
              LM.leftShoulder,
              minConfidence: kMinLandmarkConfidence,
            ),
            current.landmark(LM.leftHip, minConfidence: kMinLandmarkConfidence),
          )
        : null;
    final r = useRight
        ? verticalDist(
            current.landmark(
              LM.rightShoulder,
              minConfidence: kMinLandmarkConfidence,
            ),
            current.landmark(
              LM.rightHip,
              minConfidence: kMinLandmarkConfidence,
            ),
          )
        : null;
    if (l != null && r != null) return (l + r) / 2.0;
    return l ?? r;
  }
}
