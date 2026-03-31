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
