import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/constants.dart';
import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import 'curl_form_analyzer_extras.dart';
import 'dtw_scorer.dart';
import 'head_stability_corroborator.dart';
import 'sagittal_sway_detector.dart';

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
class CurlFormAnalyzer extends CurlAnalyzer {
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
  @override
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

  /// Peak forward-lean delta (degrees) relative to rep-start baseline.
  /// Only populated in side views; 0.0 otherwise.
  double _maxLeanDeltaDeg = 0.0;

  /// Torso angle from vertical captured at rep start (side views only).
  /// Null when view is unknown or front — lean check is skipped.
  double? _baselineTorsoAngle;

  /// Torso length (shoulder→hip vertical distance) captured at rep start.
  /// Front-view depth-swing baseline: as the lifter rocks toward the camera
  /// the apparent torso grows; rocking back, it shrinks. ML Kit gives us no
  /// real Z, so apparent size IS the depth signal. Null when the rep started
  /// without a usable torso measurement.
  double? _baselineTorsoLen;

  /// Peak |ΔtorsoLen / L_baseline| seen this rep (front view only). Drives
  /// the depth-swing quality deduction.
  double _maxDepthRatio = 0.0;

  /// Sagittal sway detector — front view only. Owns its own 1€ filters,
  /// per-feature baselines, σ-drift cap, dt anomaly guard, and hysteresis.
  /// We feed it every front-view evaluate() frame and let it decide when
  /// the user is rocking toward/away from the camera. The analyzer only
  /// translates `direction` → `FormError.depthSwing` and tracks the
  /// peak |compositeZ| seen this rep for quality scoring.
  final SagittalSwayDetector _swayDetector = SagittalSwayDetector();

  /// Head stability corroborator — front view only. Independent of
  /// `_swayDetector`: tracks `nose.y` and inter-ear distance to decide
  /// whether the head moved in sympathy with a detected sway. Used as
  /// a VETO at the depth-swing emission point — when the head is
  /// stationary but the sway detector fires, the warning is
  /// suppressed as occlusion artifact (the curling arm shadowing the
  /// torso). Fail-open when head landmarks are unavailable, so the
  /// veto can only suppress false positives, never introduce false
  /// negatives. See `HeadStabilityCorroborator` for the full rationale.
  final HeadStabilityCorroborator _headCorroborator =
      HeadStabilityCorroborator();

  /// Peak |composite z-score| seen this rep — drives the depth-swing
  /// quality deduction once the detector has a baseline. 0.0 until the
  /// detector emits its first non-null compositeZ.
  double _maxAbsSwayZ = 0.0;

  /// Hip-relative shoulder vector at rep start (side views only). Subtracting
  /// the hip cancels whole-body translation, leaving only the rotational
  /// (semicircle) component of the shoulder's motion around the hip joint.
  double? _baselineShoulderRelX;
  double? _baselineShoulderRelY;

  /// Peak shoulder-arc displacement / torso length seen this rep. Drives the
  /// shoulder-arc quality deduction (side views only).
  double _maxShoulderArcRatio = 0.0;
  double _lastRepQuality = 1.0;
  final List<double> _repQualities = [];

  /// Set once after view detection locks (called by RepCounter).
  /// View change invalidates the sway baseline (different camera framing
  /// → different `(μ, σ)`), so reset the detector.
  @override
  void setView(CurlCameraView view) {
    if (view != _view) {
      _swayDetector.reset();
      _headCorroborator.reset();
    }
    _view = view;
  }

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
    _maxLeanDeltaDeg = 0.0;
    _baselineTorsoAngle = _sideViewTorsoAngle(snapshot);

    // Depth-swing baseline (front view): snapshot the apparent torso length.
    // We re-derive it the same way `evaluate()` does so the ratio is
    // dimensionless and self-consistent across frames.
    //
    // NOTE: this `_baselineTorsoLen` field is now retained only for
    // legacy diagnostics — the active depth-swing decision is made by
    // `_swayDetector` which owns its own per-feature baselines and
    // does not consult this value. We keep the snapshot so any
    // out-of-tree consumer that read `_baselineTorsoLen` for telemetry
    // continues to work.
    _maxDepthRatio = 0.0;
    _maxAbsSwayZ = 0.0;
    _baselineTorsoLen = _view == CurlCameraView.front
        ? _computeTorsoLen(
            snapshot,
            _view != CurlCameraView.sideRight,
            _view != CurlCameraView.sideLeft,
          )
        : null;

    // Shoulder-arc baseline (side views): snapshot the shoulder position in
    // the hip's local frame so subsequent measurements isolate rotation, not
    // translation.
    _maxShoulderArcRatio = 0.0;
    _baselineShoulderRelX = null;
    _baselineShoulderRelY = null;
    if (_view == CurlCameraView.sideLeft || _view == CurlCameraView.sideRight) {
      final useLeft = _view == CurlCameraView.sideLeft;
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
      }
    }
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
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];
    final effectiveNow = now ?? DateTime.now();

    // Depth swing (front view only) — sagittal rocking toward/away from the
    // camera. The 2D pose has no real Z, so we project apparent body
    // geometry onto a composite scale-invariant signal and classify its
    // time-normalized velocity. See `SagittalSwayDetector` for the full
    // signal-processing rationale.
    //
    // Baseline eligibility: only feed (μ, σ) when the user is at the
    // bottom of a rep — i.e. before the FSM has stamped a rep-start
    // snapshot, OR right at the start of the concentric phase. We
    // feed the detector every front-view frame; the `allowBaseline`
    // flag ensures reps don't poison the neutral-pose baseline.
    if (_view == CurlCameraView.front) {
      // ── Layer 2: head stability corroborator ──────────────
      // Run UNCONDITIONALLY (independent of the occlusion gate below).
      // The head sits above the arm-over-torso occlusion zone, so its
      // landmarks are unaffected by the artifact that fools the sway
      // detector — we want the corroborator's baseline to grow on
      // every front-view frame, including ones where the arm crosses
      // the torso. Used as a veto at the emission point further down.
      final headResult = _headCorroborator.update(
        pose: current,
        now: effectiveNow,
        allowBaseline: _repStartSnapshot == null,
      );

      // ── Layer 1: arm-over-torso occlusion gate ────────────
      // When the curling arm is currently inside the torso bounding
      // box, ML Kit's shoulder/hip landmarks drift even though their
      // confidence stays high. Skip the sway detector entirely — no
      // baseline poison, no velocity update. This prevents the false
      // signal at its source rather than catching it after the fact.
      final occluded = _armOccludesTorso(current);
      if (!occluded) {
        final swayResult = _swayDetector.update(
          pose: current,
          now: effectiveNow,
          allowBaseline: _repStartSnapshot == null,
        );
        final z = swayResult.compositeZ;
        if (z != null) {
          final absZ = z.abs();
          // Only track peak for quality deduction if a rep is in flight.
          if (_repStartSnapshot != null && absZ > _maxAbsSwayZ) {
            _maxAbsSwayZ = absZ;
          }
        }
        // Only report the error if a rep is in flight. Prevents cues
        // while the user is standing still or adjusting between reps.
        if (_repStartSnapshot != null &&
            swayResult.direction != SagittalSwayDirection.neutral) {
          if (_headCorroboratesMotion(headResult)) {
            errors.add(FormError.depthSwing);
          } else {
            // Telemetry hook — surfaces every veto so we can tune
            // `kHeadCorroborationMinZ` empirically without rebuilds.
            debugPrint(
              'depthSwing vetoed: head stationary '
              '(verticalZ=${headResult.verticalZ?.toStringAsFixed(2)}, '
              'scaleZ=${headResult.scaleZ?.toStringAsFixed(2)})',
            );
          }
        }

        // Legacy peak-ratio tracker — preserved for out-of-tree telemetry
        // consumers but no longer participates in the decision. Computed
        // off the rep-start snapshot's torso length, same as before.
        if (_baselineTorsoLen != null) {
          final base = _baselineTorsoLen!;
          if (base > 0.01) {
            final useLeft = _view != CurlCameraView.sideRight;
            final useRight = _view != CurlCameraView.sideLeft;
            final torsoLen = _computeTorsoLen(current, useLeft, useRight);
            if (torsoLen != null) {
              final depthRatio = (torsoLen - base).abs() / base;
              if (depthRatio > _maxDepthRatio) _maxDepthRatio = depthRatio;
            }
          }
        }
      }
    }

    final ref = _repStartSnapshot;
    if (ref == null) return errors;

    final useLeft = _view != CurlCameraView.sideRight;
    final useRight = _view != CurlCameraView.sideLeft;

    final torsoLen = _computeTorsoLen(current, useLeft, useRight);
    if (torsoLen == null || torsoLen < 0.01) return errors;

    // Torso swing (lateral, both views).
    final swing =
        (useLeft ? horizontalShift(ref, current, LM.leftShoulder) : null) ??
        (useRight ? horizontalShift(ref, current, LM.rightShoulder) : null);
    if (swing != null) {
      final ratio = swing / torsoLen;
      if (ratio > _maxSwingRatio) _maxSwingRatio = ratio;
      if (ratio > kSwingThreshold) errors.add(FormError.torsoSwing);
    }

    // Forward trunk lean (side views only — front view collapses the sagittal
    // plane into depth, making the angle unreliable).
    final baseline = _baselineTorsoAngle;
    if (baseline != null &&
        (_view == CurlCameraView.sideLeft ||
            _view == CurlCameraView.sideRight)) {
      final currentAngle = _sideViewTorsoAngle(current);
      if (currentAngle != null) {
        final delta = (currentAngle - baseline).abs();
        if (delta > _maxLeanDeltaDeg) _maxLeanDeltaDeg = delta;
        if (delta > kTorsoLeanThresholdDeg &&
            !errors.contains(FormError.torsoSwing)) {
          errors.add(FormError.torsoSwing);
        }
      }
    }

    // Shoulder arc (side views only) — hip-pivot rotation. Anchoring the
    // shoulder vector at the hip cancels whole-body translation, leaving
    // only the rotational component (the "semicircle" the shoulder traces
    // when the lifter pivots their torso forward/back at the hip joint).
    if ((_view == CurlCameraView.sideLeft ||
            _view == CurlCameraView.sideRight) &&
        _baselineShoulderRelX != null &&
        _baselineShoulderRelY != null) {
      final useLeftSide = _view == CurlCameraView.sideLeft;
      final shoulder = current.landmark(
        useLeftSide ? LM.leftShoulder : LM.rightShoulder,
        minConfidence: kMinLandmarkConfidence,
      );
      final hip = current.landmark(
        useLeftSide ? LM.leftHip : LM.rightHip,
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
    _maxLeanDeltaDeg = 0.0;
    _baselineTorsoAngle = null;
    _baselineTorsoLen = null;
    _maxDepthRatio = 0.0;
    _maxAbsSwayZ = 0.0;
    _swayDetector.reset();
    _headCorroborator.reset();
    _baselineShoulderRelX = null;
    _baselineShoulderRelY = null;
    _maxShoulderArcRatio = 0.0;
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

    // Depth swing — severity from the sway detector's peak |z-score|.
    // The detector classifies on velocity (an event signal); the z-score
    // magnitude tells us how far from neutral the user got at the worst
    // moment of the rep, which is the right scalar for "how bad was it."
    // Severity ramps from `kSagittalVelocityThreshold` (just barely
    // tripped) to 2× that (clearly out of band). Reuses the swing
    // deduction budget — same cheat family, same penalty budget.
    if (_maxAbsSwayZ > kSagittalVelocityThreshold) {
      final severity =
          ((_maxAbsSwayZ - kSagittalVelocityThreshold) /
                  kSagittalVelocityThreshold)
              .clamp(0.0, 1.0);
      score -= severity * kQualitySwingMaxDeduction;
    }

    // Shoulder arc — same severity curve & cap.
    if (_maxShoulderArcRatio > kSwingThreshold) {
      final severity =
          ((_maxShoulderArcRatio - kSwingThreshold) / kSwingThreshold).clamp(
            0.0,
            1.0,
          );
      score -= severity * kQualitySwingMaxDeduction;
    }

    // Forward lean deduction (side views only — same cap as swing).
    if (_maxLeanDeltaDeg > kTorsoLeanThresholdDeg) {
      final severity =
          ((_maxLeanDeltaDeg - kTorsoLeanThresholdDeg) / kTorsoLeanThresholdDeg)
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
  @override
  Duration? get lastConcentricDuration => _lastConcentricDuration;

  // ── Side-view telemetry stubs ──────────────────────────
  // The front analyzer has no side-view metrics. These exist only so the
  // umbrella `CurlAnalyzer` type can be read uniformly by callers that
  // don't know which view is active (`WorkoutViewModel` per-rep commit
  // handler — gates on `ExerciseType.bicepsCurlSide` before reading these,
  // so the stubs are never observed in practice; declared for type
  // completeness only).

  @override
  double? get lastSignedElbowDriftRatio => null;

  @override
  double? get signedElbowDriftRatioAtMax => null;

  @override
  double get maxElbowDriftRatioThisRep => 0.0;

  @override
  double get maxTorsoLeanDegThisRep => 0.0;

  @override
  double get maxShoulderDriftRatioThisRep => 0.0;

  @override
  double get maxBackLeanDegThisRep => 0.0;

  /// Torso angle from vertical for side-view lean detection.
  /// Uses the near-side shoulder→hip segment. Returns null when either
  /// landmark is missing or below confidence.
  double? _sideViewTorsoAngle(PoseResult pose) {
    final useLeft = _view == CurlCameraView.sideLeft;
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

  /// True when the curling-arm wrist OR elbow is currently inside the
  /// torso bounding box, indicating ML Kit's torso landmarks are
  /// likely drifting due to occlusion. Front view checks both arms;
  /// side views check only the camera-facing arm. Fail-open (returns
  /// `false`) when any required landmark is missing — never makes
  /// detection more aggressive than today.
  ///
  /// Definition of "inside the box":
  ///   `xMin = min(ls.x, rs.x)`, `xMax = max(ls.x, rs.x)`
  ///   `yMin = min(ls.y, rs.y)`, `yMax = max(lh.y, rh.y)`
  /// A joint is occluding when `xMin ≤ joint.x ≤ xMax` AND
  /// `yMin ≤ joint.y ≤ yMax`.
  bool _armOccludesTorso(PoseResult pose) {
    final ls = pose.landmark(
      LM.leftShoulder,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final rs = pose.landmark(
      LM.rightShoulder,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final lh = pose.landmark(
      LM.leftHip,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final rh = pose.landmark(
      LM.rightHip,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    if (ls == null || rs == null || lh == null || rh == null) return false;

    final xMin = math.min(ls.x, rs.x);
    final xMax = math.max(ls.x, rs.x);
    final yMin = math.min(ls.y, rs.y);
    final yMax = math.max(lh.y, rh.y);

    bool inside(double x, double y) =>
        x >= xMin && x <= xMax && y >= yMin && y <= yMax;

    final checkLeft = _view != CurlCameraView.sideRight;
    final checkRight = _view != CurlCameraView.sideLeft;

    if (checkLeft) {
      final lw = pose.landmark(
        LM.leftWrist,
        minConfidence: kSagittalMinLandmarkVisibility,
      );
      final le = pose.landmark(
        LM.leftElbow,
        minConfidence: kSagittalMinLandmarkVisibility,
      );
      if (lw != null && inside(lw.x, lw.y)) return true;
      if (le != null && inside(le.x, le.y)) return true;
    }
    if (checkRight) {
      final rw = pose.landmark(
        LM.rightWrist,
        minConfidence: kSagittalMinLandmarkVisibility,
      );
      final re = pose.landmark(
        LM.rightElbow,
        minConfidence: kSagittalMinLandmarkVisibility,
      );
      if (rw != null && inside(rw.x, rw.y)) return true;
      if (re != null && inside(re.x, re.y)) return true;
    }
    return false;
  }

  /// Decide whether a depth-swing detection is corroborated by head
  /// motion. Returns `true` (no veto, emit the warning) when the head
  /// shows enough motion to confirm a real spinal sway. Returns
  /// `false` (veto, suppress the warning) when the head is stationary,
  /// indicating the sway detector likely fired on arm-occlusion
  /// artifact.
  ///
  /// **Fail-open contract:** if head landmarks are unavailable or the
  /// corroborator's baseline has not yet closed, return `true` —
  /// never make detection worse than the baseline (sway-detector-only)
  /// behavior.
  bool _headCorroboratesMotion(HeadCorroborationResult r) {
    if (!r.landmarksAvailable || !r.baselineReady) return true;
    final vZ = (r.verticalZ ?? 0).abs();
    final sZ = (r.scaleZ ?? 0).abs();
    return (kHeadVerticalWeight * vZ + kHeadScaleWeight * sZ) >=
        kHeadCorroborationMinZ;
  }

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
