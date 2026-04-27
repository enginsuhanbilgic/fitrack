/// Shared enums used across the app.
library;

/// Exercises the app supports.
enum ExerciseType {
  bicepsCurlFront('Biceps Curl (Front)'),
  bicepsCurlSide('Biceps Curl (Side)'),
  // ignore: deprecated_member_use_from_same_package
  @Deprecated('Use bicepsCurlFront or bicepsCurlSide')
  bicepsCurl('Biceps Curl'),
  squat('Squat'),
  pushUp('Push-up');

  final String label;
  const ExerciseType(this.label);

  /// True for any biceps-curl variant (front or side view).
  bool get isCurl =>
      this == ExerciseType.bicepsCurlFront ||
      this == ExerciseType.bicepsCurlSide ||
      // ignore: deprecated_member_use_from_same_package
      this == ExerciseType.bicepsCurl;
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
  torsoSwing, // momentum abuse — lateral (X-axis) shoulder shift
  depthSwing, // sagittal swing toward/away from camera — detected via scale-invariant torso features (front view only)
  shoulderArc, // hip-pivot rotation — detected via shoulder displacement in hip-relative frame (side views only)
  elbowDrift, // elbow moving forward/backward
  shoulderShrug, // lifting shoulders up (trapezius involvement)
  backLean, // excessive backward lean (hyperextension)
  shortRomStart, // rep started without reaching full extension (maxAngle < startAngle − tol)
  shortRomPeak, // abandoned rep — never reached peak (minAngle > peakAngle + tol)
  // Squat
  squatDepth, // rep completed without reaching bottom threshold
  // DEPRECATED 2026-04-25 (Squat Master Rebuild): superseded by `excessiveForwardLean`.
  // Retained in the enum so legacy WP5 session rows continue to deserialize via
  // `FormError.values.byName('trunkTibia')`. Not emitted by new code.
  trunkTibia, // (legacy) trunk-tibia parallelism deviation > 15°
  // Squat — added 2026-04-25 (Squat Master Rebuild)
  excessiveForwardLean, // trunk-from-vertical > kSquatLeanWarnDeg (45° BW / 50° HBBS)
  forwardKneeShift, // (knee_x − ankle_x) / femur_len > kSquatKneeShiftWarnRatio — informational, no TTS
  heelLift, // (foot_index_y − heel_y) / leg_len > kSquatHeelLiftWarnRatio
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

/// Squat variant — toggles the lean threshold. User-declared at workout start
/// via the HomeScreen modal sheet; persisted in `PreferencesRepository`.
///
/// Bodyweight squat tolerates less forward lean (45°) because the lifter has
/// no posterior counterbalance; high-bar back squat tolerates a bit more (50°)
/// because the bar load shifts the system's center of mass slightly forward.
enum SquatVariant {
  bodyweight('Bodyweight'),
  highBarBackSquat('Barbell back squat');

  final String label;
  const SquatVariant(this.label);
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

/// Per-rep squat metrics captured at commit time. Index-aligned with the
/// session's rep order. Only populated when the workout is a squat — empty
/// list otherwise. Used by the summary screen to render per-rep ratio
/// metrics (lean / knee-shift / heel-lift) in addition to the global average.
///
/// Lives in `core/types.dart` (not `view_models/`) so the summary screen
/// can import it without reaching across layers — mirrors the placement of
/// `CurlRepRecord` and `CurlProfileBucketSummary`.
class SquatRepMetrics {
  const SquatRepMetrics({
    required this.repIndex,
    required this.quality,
    required this.leanDeg,
    required this.kneeShiftRatio,
    required this.heelLiftRatio,
  });

  final int repIndex;
  final double? quality;
  final double? leanDeg;
  final double? kneeShiftRatio;
  final double? heelLiftRatio;
}

/// Per-rep biceps-curl side-view form metrics. Populated only when the
/// active exercise is `bicepsCurlSide` AND the locked view is one of
/// `sideLeft` / `sideRight`. Values are the analyzer's per-rep max
/// observations as of rep commit (cleared at the next rep's `onRepStart`).
///
/// Lives in `core/types.dart` (not `view_models/`) so the summary screen
/// can import it without reaching across layers — mirrors [SquatRepMetrics].
class BicepsSideRepMetrics {
  const BicepsSideRepMetrics({
    required this.repIndex,
    required this.leanDeg,
    required this.shoulderDriftRatio,
    required this.elbowDriftRatio,
    required this.backLeanDeg,
    this.elbowDriftSigned,
  });

  final int repIndex;

  /// Peak forward-trunk-lean delta (degrees) relative to rep-start
  /// baseline. Drives the `kTorsoLeanThresholdDeg` flag inside
  /// `CurlSideFormAnalyzer`.
  final double? leanDeg;

  /// Peak shoulder-arc displacement ratio — `disp / torso_len` measured in
  /// hip-relative coordinates. Drives the side-view `shoulderArc` flag.
  final double? shoulderDriftRatio;

  /// Peak absolute torso-perpendicular elbow-offset ratio
  /// (`|signedRatio|`). Drives the `kDriftThreshold` flag.
  final double? elbowDriftRatio;

  /// Peak back-lean (hyperextension) degrees. Drives the `kBackLeanThresholdDeg`
  /// flag. Sign-corrected for facing direction.
  final double? backLeanDeg;

  /// Signed elbow-drift ratio captured at the frame where the absolute
  /// peak ([elbowDriftRatio]) was set. Sign convention: positive = elbow
  /// on the +n̂ side of the torso axis (n̂ = (−u_y, u_x), u = (S − H)/|S − H|).
  /// Lets the retune pipeline distinguish forward-elbow cheats from
  /// back-elbow ones — the magnitude alone collapses both into one bucket.
  /// Null on side-view rows from before this column shipped.
  final double? elbowDriftSigned;
}

/// Required ML Kit landmark indices per exercise.
class ExerciseRequirements {
  final List<int> landmarkIndices;
  const ExerciseRequirements(this.landmarkIndices);

  static ExerciseRequirements forExercise(ExerciseType type) {
    switch (type) {
      case ExerciseType.bicepsCurlFront:
      case ExerciseType.bicepsCurlSide:
      // ignore: deprecated_member_use_from_same_package
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

  /// View-aware required-landmark set. Returns only the landmarks that
  /// are reasonably trackable for the given (exercise, view) combination.
  /// Side-view curls only reliably track the near-side arm — the off-camera
  /// arm projects behind the body and ML Kit can't localize its landmarks.
  /// Requiring both sides causes the pose-quality gate to reject every
  /// frame in side view, starving the FSM of input.
  ///
  /// Front-view and unknown-view fall through to [forExercise] (both arms).
  /// All non-curl exercises also fall through.
  static ExerciseRequirements forExerciseAndView(
    ExerciseType type,
    CurlCameraView view,
  ) {
    if (type == ExerciseType.bicepsCurlSide ||
        // ignore: deprecated_member_use_from_same_package
        type == ExerciseType.bicepsCurl) {
      if (view == CurlCameraView.sideLeft) {
        // Left shoulder (11), left elbow (13), left wrist (15).
        return const ExerciseRequirements([11, 13, 15]);
      }
      if (view == CurlCameraView.sideRight) {
        // Right shoulder (12), right elbow (14), right wrist (16).
        return const ExerciseRequirements([12, 14, 16]);
      }
    }
    return forExercise(type);
  }
}
