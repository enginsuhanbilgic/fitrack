import 'constants.dart';
import 'types.dart';

class ExerciseTargetConfig {
  const ExerciseTargetConfig({
    required this.presets,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.isTimed,
  });

  final List<int> presets;
  final int min;
  final int max;
  final int defaultValue;
  final bool isTimed;

  static ExerciseTargetConfig forExercise(ExerciseType exercise) {
    if (exercise.isCurl) {
      return const ExerciseTargetConfig(
        presets: [8, 12, 20],
        min: 1,
        max: 40,
        defaultValue: 12,
        isTimed: false,
      );
    }
    return switch (exercise) {
      ExerciseType.pushUp => const ExerciseTargetConfig(
        presets: [8, 16, 32],
        min: 1,
        max: 120,
        defaultValue: 16,
        isTimed: false,
      ),
      ExerciseType.squat => const ExerciseTargetConfig(
        presets: [6, 12, 18],
        min: 1,
        max: 32,
        defaultValue: 12,
        isTimed: false,
      ),
      ExerciseType.plank => const ExerciseTargetConfig(
        presets: [30, 60, 120],
        min: 1,
        max: 600,
        defaultValue: kPlankTargetHoldSeconds,
        isTimed: true,
      ),
      _ => const ExerciseTargetConfig(
        presets: [8, 12, 20],
        min: 1,
        max: 40,
        defaultValue: 12,
        isTimed: false,
      ),
    };
  }

  int sanitize(int? value) {
    final raw = value ?? defaultValue;
    return raw.clamp(min, max).toInt();
  }

  String labelFor(int value) {
    if (!isTimed) return '$value reps';
    return '$value sec (${formatSeconds(value)})';
  }

  static String formatSeconds(int seconds) {
    final minutes = seconds ~/ 60;
    final remainder = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$remainder';
  }
}
