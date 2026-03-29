enum ExerciseStage { up, down, unknown }

class BenchmarkStats {
  final double avgFps;
  final double rollingFps; // 1-second window
  final double latencyMs;
  final double stabilityJitter; // lower = more stable

  // Exercise Metrics
  final int repCount;
  final ExerciseStage stage;
  final double? jointAngle; // in degrees

  const BenchmarkStats({
    required this.avgFps,
    required this.rollingFps,
    required this.latencyMs,
    required this.stabilityJitter,
    required this.repCount,
    required this.stage,
    this.jointAngle,
  });

  factory BenchmarkStats.zero() => const BenchmarkStats(
        avgFps: 0,
        rollingFps: 0,
        latencyMs: 0,
        stabilityJitter: 0,
        repCount: 0,
        stage: ExerciseStage.unknown,
        jointAngle: null,
      );

  String get stageLabel {
    switch (stage) {
      case ExerciseStage.up: return 'UP';
      case ExerciseStage.down: return 'DOWN';
      case ExerciseStage.unknown: return 'UNKNOWN';
    }
  }
}
