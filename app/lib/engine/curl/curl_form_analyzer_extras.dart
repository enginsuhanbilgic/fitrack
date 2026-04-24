import '../../core/rom_thresholds.dart';
import '../../core/types.dart';

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
}
