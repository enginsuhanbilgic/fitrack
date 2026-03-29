import 'package:flutter/material.dart';
import '../models/benchmark_stats.dart';
import '../screens/home_screen.dart' hide Colors;

class MetricsOverlay extends StatelessWidget {
  final String modelName;
  final BenchmarkStats stats;
  final int landmarkCount;
  final int framesProcessed;
  final ExerciseType exerciseType;

  const MetricsOverlay({
    super.key,
    required this.modelName,
    required this.stats,
    required this.landmarkCount,
    required this.exerciseType,
    this.framesProcessed = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            modelName,
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 6),
          _metricRow('FPS (1s)', stats.rollingFps.toStringAsFixed(1), _fpsColor(stats.rollingFps)),
          _metricRow('Latency', '${stats.latencyMs.toStringAsFixed(1)} ms', _latencyColor(stats.latencyMs)),
          _metricRow('Jitter', stats.stabilityJitter.toStringAsFixed(4), Colors.white70),
          _metricRow('Reps', '${stats.repCount}', Colors.cyanAccent),
          _metricRow('Stage', stats.stageLabel, stats.stage == ExerciseStage.unknown ? Colors.white38 : Colors.greenAccent),
          _metricRow(_angleLabel(), stats.jointAngle != null ? '${stats.jointAngle!.toStringAsFixed(1)}°' : '--', Colors.yellowAccent),
          _metricRow('Landmarks', '$landmarkCount', Colors.white70),
          if (framesProcessed > 0)
            _metricRow('Frames', '$framesProcessed', Colors.white70),
        ],
      ),
    );
  }

  String _angleLabel() => switch (exerciseType) {
    ExerciseType.bicepCurlFront || ExerciseType.bicepCurlLeft || ExerciseType.bicepCurlRight => 'Elbow°',
  };

  Widget _metricRow(String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Text(value, style: TextStyle(color: valueColor, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Color _fpsColor(double fps) {
    if (fps >= 20) return Colors.greenAccent;
    if (fps >= 10) return Colors.yellowAccent;
    return Colors.redAccent;
  }

  Color _latencyColor(double ms) {
    if (ms <= 50) return Colors.greenAccent;
    if (ms <= 100) return Colors.yellowAccent;
    return Colors.redAccent;
  }
}
