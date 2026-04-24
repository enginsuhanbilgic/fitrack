/// Shared enums used across the app.
library;

/// Exercises the app supports.
enum ExerciseType {
  bicepsCurl('Biceps Curl'),
  squat('Squat'),
  pushUp('Push-up');

  final String label;
  const ExerciseType(this.label);
}

/// Which side the user is training (affects which arm/leg we track).
enum ExerciseSide { left, right, both }

/// Rep FSM states — curl uses concentric/peak/eccentric; squat+push-up use descending/bottom/ascending.
enum RepState {
  idle,
  // Biceps curl phases
  concentric, // lifting phase
  peak, // top of curl
  eccentric, // lowering phase
  // Squat + push-up phases
  descending, // moving down
  bottom, // lowest point reached
  ascending, // moving back up
}

/// Types of form errors we can detect.
enum FormError {
  // Biceps curl
  torsoSwing, // momentum abuse
  elbowDrift, // elbow moving forward/backward
  shortRomStart, // rep started without reaching full extension (maxAngle < startAngle − tol)
  shortRomPeak, // abandoned rep — never reached peak (minAngle > peakAngle + tol)
  // Squat
  squatDepth, // rep completed without reaching bottom threshold
  trunkTibia, // trunk-tibia parallelism deviation > 15°
  // Push-up
  hipSag, // shoulder-hip-ankle collinearity deviation > 15°
  pushUpShortRom, // rep completed without elbow reaching bottom threshold
  // Biceps curl — advanced
  eccentricTooFast, // eccentric phase < kMinEccentricSec
  concentricTooFast, // concentric phase < kMinConcentricSec (flinging the weight)
  tempoInconsistent, // concentric variance > kTempoInconsistencyRatio over last N
  asymmetryLeftLag, // left arm min-angle higher (shallower flexion) — "Left arm is lagging"
  asymmetryRightLag, // right arm min-angle higher (shallower flexion) — "Right arm is lagging"
  fatigue, // concentric velocity degrading across reps
}

/// Top-level session lifecycle state.
///
/// `calibration` runs only when forced (Settings → Recalibrate) or when no
/// profile exists and the user has not opted out. It reuses the same camera
/// and pose stream as the rest of the workout — it is a phase, not a route.
enum WorkoutPhase { calibration, setupCheck, countdown, active, completed }

/// Concrete arm/leg identifier used by the per-user ROM profile.
///
/// Distinct from [ExerciseSide] because a profile bucket only ever describes
/// one physical limb — `both` or `unknown` are never valid bucket keys.
enum ProfileSide { left, right }

/// Where the active FSM thresholds for the current rep came from.
///
/// Promoted only at IDLE→CONCENTRIC (see plan invariant) so the source for a
/// rep is fixed for that rep's whole lifetime. Used by telemetry + diagnostics.
enum ThresholdSource {
  /// Loaded from a calibrated profile bucket (≥ kCalibrationMinReps samples).
  calibrated,

  /// Built in-set by the auto-calibrator after observing ≥ 2 reps.
  autoCalibrated,

  /// Calibrated/auto thresholds with the warmup multiplier applied (first reps of a set).
  warmup,

  /// Falling back to the global `kCurl*` constants — no profile, no auto data yet.
  global,
}

/// Camera orientation detected automatically during SETUP_CHECK (biceps curl only).
/// Locked once; never re-detected mid-session.
enum CurlCameraView {
  unknown, // detection not yet complete
  front, // user faces camera — both shoulders broadly separated on X axis
  sideLeft, // user's left side faces camera — left shoulder is near-side
  sideRight, // user's right side faces camera — right shoulder is near-side
}

/// Per-rep detail captured when the curl FSM commits a rep.
///
/// Used only for reporting (the summary screen's Details panel + telemetry).
/// NOT consumed by the engine — engine state lives in `RepSnapshot`.
class CurlRepRecord {
  /// 1-based rep index within the session (not the set).
  final int repIndex;
  final ProfileSide side;
  final CurlCameraView view;
  final double minAngle;
  final double maxAngle;

  /// Which source drove the FSM thresholds for this rep. Derived at commit
  /// time by re-running the resolver (same chain the FSM used).
  final ThresholdSource source;

  /// True if the rep updated the bucket (initialized or applied).
  /// False for shrink-pending, outlier-rejected, or when the bucket wasn't
  /// touched (unknown view drops the commit upstream).
  final bool bucketUpdated;

  /// True if the bucket's outlier guard rejected this sample.
  final bool rejectedOutlier;

  const CurlRepRecord({
    required this.repIndex,
    required this.side,
    required this.view,
    required this.minAngle,
    required this.maxAngle,
    required this.source,
    required this.bucketUpdated,
    required this.rejectedOutlier,
  });

  double get romDegrees => maxAngle - minAngle;
}

/// Snapshot of a single `(side, view)` bucket at summary-screen open time.
///
/// Decoupled from `RomBucket` so the summary screen doesn't need to import
/// the engine — pure value class, safe to pass across layers.
class CurlProfileBucketSummary {
  final ProfileSide side;
  final CurlCameraView view;
  final double observedMinAngle;
  final double observedMaxAngle;
  final int sampleCount;
  final DateTime lastUpdated;
  final bool isCalibrated;

  /// Reps this session that committed to this bucket (updated or pending).
  final int sessionReps;

  const CurlProfileBucketSummary({
    required this.side,
    required this.view,
    required this.observedMinAngle,
    required this.observedMaxAngle,
    required this.sampleCount,
    required this.lastUpdated,
    required this.isCalibrated,
    required this.sessionReps,
  });

  double get romDegrees => observedMaxAngle - observedMinAngle;
}

/// Required ML Kit landmark indices per exercise.
class ExerciseRequirements {
  final List<int> landmarkIndices;
  const ExerciseRequirements(this.landmarkIndices);

  static ExerciseRequirements forExercise(ExerciseType type) {
    switch (type) {
      case ExerciseType.bicepsCurl:
        // Shoulders (11,12), elbows (13,14), wrists (15,16).
        // Hips excluded — they flicker below confidence on close-up front cam
        // and are not essential for curl rep counting or form analysis.
        return const ExerciseRequirements([11, 12, 13, 14, 15, 16]);
      case ExerciseType.squat:
        return const ExerciseRequirements([23, 24, 25, 26, 27, 28]);
      case ExerciseType.pushUp:
        return const ExerciseRequirements([
          11,
          12,
          13,
          14,
          15,
          16,
          23,
          24,
          25,
          26,
        ]);
    }
  }
}
