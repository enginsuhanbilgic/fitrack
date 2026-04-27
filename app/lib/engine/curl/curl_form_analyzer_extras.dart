import '../../core/rom_thresholds.dart';
import '../../core/types.dart';
import '../form_analyzer_base.dart';
import 'dtw_scorer.dart';

/// Curl-only extensions beyond [FormAnalyzerBase].
///
/// Exposed as a mixin so `CurlStrategy` can hold the form analyzer as a
/// `FormAnalyzerBase & CurlFormAnalyzerExtras` intersection type and never
/// needs to downcast at call sites. Squat / push-up analyzers implement only
/// the base contract — these extras are intentionally curl-specific because
/// only the curl FSM has multi-rep quality scoring, asymmetry, tempo, and
/// view-aware thresholds.
mixin CurlFormAnalyzerExtras {
  /// Locks the analyzer to a detected camera view. Called once by the host
  /// when `CurlViewDetector` reaches consensus. Affects swing/drift landmark
  /// selection (front → use both shoulders; side → use the visible one).
  void setView(CurlCameraView view);

  /// Pushes the thresholds the FSM is gating against for the current rep.
  /// Called at the IDLE → CONCENTRIC promotion site so `onAbortedRep` uses
  /// the same thresholds the FSM sees — never mid-rep.
  void setActiveThresholds(RomThresholds thresholds);

  /// Call at CONCENTRIC → PEAK.
  void onPeakReached();

  /// Call at PEAK → ECCENTRIC.
  void onEccentricStart();

  /// Call when CONCENTRIC → IDLE without reaching PEAK. Classifies the
  /// shortfall against the active thresholds.
  void onAbortedRep({
    required double maxAngleAtStart,
    required double minAngleReached,
  });

  /// Record bilateral peak angles at rep completion (front view only).
  /// No-op for side views.
  void recordBilateralAngles(double? leftAngle, double? rightAngle);

  /// Finalize per-rep quality score, tempo tracking, and drain per-rep
  /// mutable state. Call at rep commit, after `consumeCompletionErrors`.
  void onRepEnd();

  double get lastRepQuality;
  double get averageQuality;
  List<double> get repQualities;
  bool get fatigueDetected;
  int get eccentricTooFastCount;
  int get concentricTooFastCount;
  int get tempoInconsistentCount;

  /// Most recent rep's concentric duration. Null until the first rep's
  /// peak is reached. Read by `CurlStrategy._commitRepSamples` so the
  /// rep-commit callback can persist tempo data per rep.
  Duration? get lastConcentricDuration;

  // ── Side-view per-rep telemetry maxes ──────────────────
  // Front analyzer returns 0.0 / null — no side-view metrics there.
  // Side analyzer overrides with real per-rep peak observations.
  // Consumed by `WorkoutViewModel` (PR 3) to persist `BicepsSideRepMetrics`.

  /// Most recent signed perpendicular elbow-offset ratio (side view only).
  /// Sign carries "elbow forward vs. back of torso axis"; flag uses
  /// magnitude. Null on the front analyzer or when landmarks are missing.
  double? get lastSignedElbowDriftRatio;

  /// Signed elbow-drift ratio captured at the frame where the absolute
  /// magnitude peaked this rep. Distinct from [lastSignedElbowDriftRatio]
  /// (which is just the most recent frame) — this is the sign of the
  /// peak. Persisted to SQLite (schema v5) and emitted in the
  /// `rep.side_metrics` TelemetryLog line so the retune pipeline can
  /// split forward-elbow vs. back-elbow cheats. Null on the front
  /// analyzer or before any valid frame this rep.
  double? get signedElbowDriftRatioAtMax;

  /// Max absolute elbow-drift ratio observed during the current rep.
  /// Cleared on rep boundary. 0.0 on the front analyzer.
  double get maxElbowDriftRatioThisRep;

  /// Max torso-lean delta in degrees observed during the current rep.
  /// 0.0 on the front analyzer.
  double get maxTorsoLeanDegThisRep;

  /// Max shoulder-arc-displacement ratio observed during the current rep.
  /// 0.0 on the front analyzer.
  double get maxShoulderDriftRatioThisRep;

  /// Max back-lean (hyperextension) degrees observed during the current
  /// rep. 0.0 on the front analyzer.
  double get maxBackLeanDegThisRep;

  /// Score a completed rep's angle trace against the reference rep, if
  /// DTW scoring is enabled and a reference is configured. Returns null
  /// when scoring is disabled or no reference exists.
  DtwScore? scoreRep(List<double> candidate);
}

/// Umbrella type for the polymorphic curl analyzer field on
/// [CurlStrategy]. Concrete subclasses (`CurlFormAnalyzer` for front,
/// `CurlSideFormAnalyzer` for side) extend [FormAnalyzerBase] with
/// [CurlFormAnalyzerExtras]; this class lets the strategy hold a
/// reference to either without per-call-site downcasts.
///
/// Empty body — the actual contract lives entirely in the parent +
/// mixin. Exists purely so Dart's type system can express
/// "FormAnalyzerBase AND CurlFormAnalyzerExtras" as a single named type.
abstract class CurlAnalyzer extends FormAnalyzerBase
    with CurlFormAnalyzerExtras {}
