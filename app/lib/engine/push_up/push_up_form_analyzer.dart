import 'dart:math' as math;

import '../../core/constants.dart';
import '../../core/types.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../angle_utils.dart';
import '../form_analyzer_base.dart';
import 'push_up_rom_profile.dart';

/// Form analyzer for side-view push-ups.
///
/// Frame-level errors:
///   - Hip sag / pike: |180 - shoulder-hip-ankle angle| > kHipSagDeviation.
///     The rep still counts, but the committed quality score is penalized.
///
/// Rep-boundary error:
///   - Partial ROM: rep completed without elbow angle reaching kPushUpBottomAngle.
class PushUpFormAnalyzer extends FormAnalyzerBase {
  PushUpFormAnalyzer({
    PushUpRomThresholds thresholds = PushUpRomThresholds.defaults,
    List<Duration> historicalConcentricDurations = const [],
  }) : _thresholds = thresholds,
       _historicalConcentricDurations = List<Duration>.unmodifiable(
         historicalConcentricDurations,
       );

  PushUpRomThresholds _thresholds;
  double? _minElbowAngle;
  double? _maxElbowAngleThisRep;
  double? _maxBodyLineDeviationDeg;
  double? _lastRepQuality;
  double? _lastBodyLineDeviationDeg;
  double? _lastRepMinElbowAngle;
  double? _lastRepMaxElbowAngle;

  // ── Tempo / fatigue tracking (2026-05-16, curl-parity) ──────────────
  // Phase mapping: DESCENDING = eccentric (lowering), ASCENDING =
  // concentric (press). Unlike curl (which stamps phase boundaries from
  // its own analyzer lifecycle callbacks using DateTime.now()), the
  // push-up analyzer has no such callbacks — the STRATEGY owns the FSM
  // and pushes the injected `input.now` timestamp in via the three
  // on*Phase methods below. This keeps the clock test-injectable, matching
  // the squat/push-up convention (NOT curl's DateTime.now()).
  DateTime? _descentStart;
  DateTime? _ascentStart;
  Duration? _lastEccentricDuration;
  Duration? _lastConcentricDuration;
  int _tempoReArmRepsRemaining = 0;
  bool _lastRepTempoInconsistent = false;
  final List<Duration> _ascentDurations = [];
  bool _fatigueFired = false;
  final List<Duration> _historicalConcentricDurations;

  /// Ascent (concentric/press) duration of the most recently committed
  /// rep, or null if the rep committed without a measured ascent phase
  /// (e.g. a shallow rep that reversed before BOTTOM). Pass-through to the
  /// host for `concentric_ms` persistence + the cross-session fatigue
  /// baseline. Mirrors `CurlSideFormAnalyzer.lastConcentricDuration`.
  Duration? get lastConcentricDuration => _lastConcentricDuration;

  /// Strategy stamps this at IDLE→DESCENDING. Resets per-rep phase timers.
  void onDescentStart(DateTime now) {
    _descentStart = now;
    _ascentStart = null;
    _lastEccentricDuration = null;
    _lastConcentricDuration = null;
  }

  /// Strategy stamps this at BOTTOM→ASCENDING. Closes the eccentric
  /// (descent) timer and opens the concentric (ascent) timer.
  void onAscentStart(DateTime now) {
    if (_descentStart != null) {
      _lastEccentricDuration = now.difference(_descentStart!);
    }
    _ascentStart = now;
  }

  /// Strategy stamps this at ASCENDING→IDLE commit, BEFORE
  /// `consumeCompletionErrors`. Closes the concentric (ascent) timer and
  /// appends to the rolling window the tempo/fatigue signals read.
  void onAscentEnd(DateTime now) {
    if (_ascentStart != null) {
      final d = now.difference(_ascentStart!);
      _lastConcentricDuration = d;
      _ascentDurations.add(d);
    }
  }

  /// Quality score for the most recently committed rep. Null until first
  /// commit. 1.0 is clean; deductions are applied for body-line loss and
  /// short ROM.
  double? get lastRepQuality => _lastRepQuality;

  /// Largest shoulder-hip-ankle deviation observed on the most recent rep.
  double? get lastBodyLineDeviationDeg => _lastBodyLineDeviationDeg;

  /// Lowest elbow angle observed during the most recently committed rep
  /// (i.e. the rep's bottom extension). Null until the first commit.
  /// Feeds the `pushup.rep` telemetry line read by the offline ROM-derivation
  /// script.
  double? get lastRepMinElbowAngle => _lastRepMinElbowAngle;

  /// Highest elbow angle observed during the most recently committed rep
  /// (i.e. the rep's top extension). Null until the first commit. Companion
  /// to [lastRepMinElbowAngle] — together they define the rep's ROM tuple.
  double? get lastRepMaxElbowAngle => _lastRepMaxElbowAngle;

  /// True when the user moved far enough down to treat the attempt as a
  /// shallow push-up if they return to full extension before reaching bottom.
  bool get hasShallowRepAttempt =>
      _minElbowAngle != null &&
      _minElbowAngle! <= _thresholds.shallowRepMaxAngle;

  void updateThresholds(PushUpRomThresholds thresholds) {
    _thresholds = thresholds;
  }

  @override
  void onRepStart(PoseResult startSnapshot) {
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
  }

  /// Call every frame during an in-progress rep to track the lowest point.
  void trackAngle(double elbowAngle) {
    if (_minElbowAngle == null || elbowAngle < _minElbowAngle!) {
      _minElbowAngle = elbowAngle;
    }
  }

  /// Per-frame max-elbow tracker. Mirrors [trackAngle] but captures the
  /// rep's top extension instead of its bottom. Called alongside
  /// [trackAngle] from `PushUpStrategy.tick()` whenever the FSM is in an
  /// active rep state. Separate accumulator from `_minElbowAngle` so the
  /// existing min-tracking contract is unchanged.
  void trackMaxElbow(double elbowAngle) {
    if (_maxElbowAngleThisRep == null || elbowAngle > _maxElbowAngleThisRep!) {
      _maxElbowAngleThisRep = elbowAngle;
    }
  }

  /// Frame-level evaluation. Counts the rep regardless of body-line quality;
  /// the error and quality score carry the fault.
  @override
  List<FormError> evaluate(PoseResult current, {DateTime? now}) {
    final errors = <FormError>[];
    final deviation = _bodyLineDeviationDeg(current);

    if (deviation != null) {
      if (_maxBodyLineDeviationDeg == null ||
          deviation > _maxBodyLineDeviationDeg!) {
        _maxBodyLineDeviationDeg = deviation;
      }
      if (deviation > kHipSagDeviation) {
        errors.add(FormError.hipSag);
      }
    }

    return errors;
  }

  /// Rep-boundary evaluation. Computes the per-rep quality score, snapshots
  /// it for the strategy to read, then clears the in-progress extrema.
  @override
  List<FormError> consumeCompletionErrors() {
    final errors = <FormError>[];
    final shortRom =
        _minElbowAngle != null && _minElbowAngle! >= _thresholds.bottomAngle;
    if (shortRom) {
      errors.add(FormError.pushUpShortRom);
    }

    // Tempo / fatigue (curl-parity). The strategy has already called
    // `onAscentEnd` before this method, so the phase durations are final.
    // Eccentric/concentric too-fast: a measured phase shorter than its
    // floor. Both nullable — a shallow rep with no ascent phase simply
    // doesn't fire (correct: there was no controlled press to grade).
    if (_lastEccentricDuration != null &&
        _lastEccentricDuration!.inMilliseconds <
            kPushUpMinEccentricSec * 1000) {
      errors.add(FormError.pushUpEccentricTooFast);
    }
    if (_lastConcentricDuration != null &&
        _lastConcentricDuration!.inMilliseconds <
            kPushUpMinConcentricSec * 1000) {
      errors.add(FormError.pushUpConcentricTooFast);
    }

    // Tempo inconsistency: sliding-window variance over ascent durations,
    // with a recoverable re-arm (mirrors curl rule 7). Decremented here
    // rather than a separate onRepEnd because push-up has no such hook.
    _lastRepTempoInconsistent = false;
    if (_tempoReArmRepsRemaining > 0) {
      _tempoReArmRepsRemaining--;
    } else if (_ascentDurations.length >= kPushUpTempoConsistencyWindow) {
      final window = _ascentDurations.sublist(
        _ascentDurations.length - kPushUpTempoConsistencyWindow,
      );
      final ms = window.map((d) => d.inMilliseconds.toDouble()).toList();
      final mean = ms.reduce((a, b) => a + b) / ms.length;
      if (mean > 0) {
        final spread =
            ms.reduce((a, b) => a > b ? a : b) -
            ms.reduce((a, b) => a < b ? a : b);
        if (spread / mean > kPushUpTempoInconsistencyRatio) {
          _lastRepTempoInconsistent = true;
          _tempoReArmRepsRemaining = kPushUpTempoConsistencyReArmReps;
        }
      }
    }
    if (_lastRepTempoInconsistent) {
      errors.add(FormError.pushUpTempoInconsistent);
    }

    // Cross-session fatigue: one-shot per session. Baseline is the larger
    // of this session's opening window and the 30-day historical median,
    // so a user who is slow today vs. their own history still trips it.
    if (!_fatigueFired && _ascentDurations.length >= kPushUpFatigueMinReps) {
      final firstAvg = _avgDurationMs(
        _ascentDurations.sublist(0, kPushUpFatigueWindowSize),
      );
      final lastAvg = _avgDurationMs(
        _ascentDurations.sublist(
          _ascentDurations.length - kPushUpFatigueWindowSize,
        ),
      );
      final baseline = math.max(firstAvg, _historicalMedianMs());
      if (baseline > 0 && lastAvg / baseline > kPushUpFatigueSlowdownRatio) {
        errors.add(FormError.pushUpFatigue);
        _fatigueFired = true;
      }
    }

    _lastRepQuality = _computeQualityScore(shortRom: shortRom);
    _lastBodyLineDeviationDeg = _maxBodyLineDeviationDeg;
    _lastRepMinElbowAngle = _minElbowAngle;
    _lastRepMaxElbowAngle = _maxElbowAngleThisRep;
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
    return errors;
  }

  static double _avgDurationMs(List<Duration> durations) {
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

  @override
  void reset() {
    _minElbowAngle = null;
    _maxElbowAngleThisRep = null;
    _maxBodyLineDeviationDeg = null;
    _lastRepQuality = null;
    _lastBodyLineDeviationDeg = null;
    _lastRepMinElbowAngle = null;
    _lastRepMaxElbowAngle = null;
    // Tempo / fatigue state — cleared on reset, mirroring
    // CurlSideFormAnalyzer.reset(). The analyzer is constructed fresh per
    // session, so this is the session-boundary clear; the fatigue one-shot
    // and tempo window do NOT survive a reset (parity with curl).
    _descentStart = null;
    _ascentStart = null;
    _lastEccentricDuration = null;
    _lastConcentricDuration = null;
    _ascentDurations.clear();
    _tempoReArmRepsRemaining = 0;
    _lastRepTempoInconsistent = false;
    _fatigueFired = false;
  }

  double _computeQualityScore({required bool shortRom}) {
    var score = 1.0;
    final deviation = _maxBodyLineDeviationDeg;
    if (deviation != null && deviation > kHipSagDeviation) {
      final severity = ((deviation - kHipSagDeviation) / kHipSagDeviation)
          .clamp(0.0, 1.0);
      score -= kQualityPushUpHipSagMaxDeduction * severity;
    }
    if (shortRom) {
      score -= kQualityPushUpShortRomDeduction;
    }
    return score.clamp(0.0, 1.0);
  }

  /// Side-view body-line deviation. Picks the visible side with stronger
  /// shoulder+hip+ankle confidence, then measures the hip angle. A straight
  /// body is near 180 degrees; both sagging and piking increase deviation.
  double? _bodyLineDeviationDeg(PoseResult p) {
    final left = _sideBodyLineDeviation(p, isLeft: true);
    final right = _sideBodyLineDeviation(p, isLeft: false);
    if (left == null && right == null) return null;
    if (left == null) return right!.deviationDeg;
    if (right == null) return left.deviationDeg;
    return left.confidenceSum >= right.confidenceSum
        ? left.deviationDeg
        : right.deviationDeg;
  }

  _BodyLineCandidate? _sideBodyLineDeviation(
    PoseResult p, {
    required bool isLeft,
  }) {
    final shoulder = p.landmark(
      isLeft ? LM.leftShoulder : LM.rightShoulder,
      minConfidence: kMinLandmarkConfidence,
    );
    final hip = p.landmark(
      isLeft ? LM.leftHip : LM.rightHip,
      minConfidence: kMinLandmarkConfidence,
    );
    final ankle = p.landmark(
      isLeft ? LM.leftAnkle : LM.rightAnkle,
      minConfidence: kMinLandmarkConfidence,
    );
    final hipAngle = angleDeg(shoulder, hip, ankle);
    if (shoulder == null || hip == null || ankle == null || hipAngle == null) {
      return null;
    }
    return _BodyLineCandidate(
      deviationDeg: (180.0 - hipAngle).abs(),
      confidenceSum: shoulder.confidence + hip.confidence + ankle.confidence,
    );
  }
}

class _BodyLineCandidate {
  const _BodyLineCandidate({
    required this.deviationDeg,
    required this.confidenceSum,
  });

  final double deviationDeg;
  final double confidenceSum;
}
