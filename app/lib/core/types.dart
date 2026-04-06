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
  concentric,  // lifting phase
  peak,        // top of curl
  eccentric,   // lowering phase
  // Squat + push-up phases
  descending,  // moving down
  bottom,      // lowest point reached
  ascending,   // moving back up
}

/// Types of form errors we can detect.
enum FormError {
  // Biceps curl
  torsoSwing,      // momentum abuse
  elbowDrift,      // elbow moving forward/backward
  shortRom,        // abandoned rep — never reached peak
  // Squat
  squatDepth,      // rep completed without reaching bottom threshold
  trunkTibia,      // trunk-tibia parallelism deviation > 15°
  // Push-up
  hipSag,          // shoulder-hip-ankle collinearity deviation > 15°
  pushUpShortRom,  // rep completed without elbow reaching bottom threshold
  // Biceps curl — advanced
  eccentricTooFast, // eccentric phase < kMinEccentricSec
  lateralAsymmetry, // left vs right peak angle delta > threshold for N reps
  fatigue,          // concentric velocity degrading across reps
}

/// Top-level session lifecycle state.
enum WorkoutPhase { setupCheck, countdown, active, completed }

/// Camera orientation detected automatically during SETUP_CHECK (biceps curl only).
/// Locked once; never re-detected mid-session.
enum CurlCameraView {
  unknown,   // detection not yet complete
  front,     // user faces camera — both shoulders broadly separated on X axis
  sideLeft,  // user's left side faces camera — left shoulder is near-side
  sideRight, // user's right side faces camera — right shoulder is near-side
}

/// Required ML Kit landmark indices per exercise.
class ExerciseRequirements {
  final List<int> landmarkIndices;
  const ExerciseRequirements(this.landmarkIndices);

  static ExerciseRequirements forExercise(ExerciseType type) {
    switch (type) {
      case ExerciseType.bicepsCurl:
        return const ExerciseRequirements([11, 12, 13, 14, 15, 16, 23, 24]);
      case ExerciseType.squat:
        return const ExerciseRequirements([23, 24, 25, 26, 27, 28]);
      case ExerciseType.pushUp:
        return const ExerciseRequirements([11, 12, 13, 14, 15, 16, 23, 24, 25, 26]);
    }
  }
}
