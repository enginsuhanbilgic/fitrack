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

/// 4-state rep FSM per the proposal (Section 2.1, Figure 5).
enum RepState {
  idle,        // arm extended, waiting
  concentric,  // lifting phase
  peak,        // top of curl
  eccentric,   // lowering phase
}

/// Types of form errors we can detect.
enum FormError {
  torsoSwing,  // momentum abuse
  elbowDrift,  // elbow moving forward/backward
  shortRom,    // half-rep / insufficient range of motion
}

/// Top-level session lifecycle state.
enum WorkoutPhase { setupCheck, active }

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
