class SessionSummary {
  final String model;
  final int durationMs;
  final int totalFrames;
  final int poseFrames;
  final double poseDetectionRate;
  final int repCount;
  
  // Latency Stats
  final double meanLatencyMs;
  final double p50LatencyMs;
  final double p95LatencyMs;
  final double minLatencyMs;
  final double maxLatencyMs;
  final double averageFps;

  // Device Info
  final String deviceManufacturer;
  final String deviceModel;
  final String androidVersion;
  
  final int startedAtEpochMs;
  final int finishedAtEpochMs;

  SessionSummary({
    required this.model,
    required this.durationMs,
    required this.totalFrames,
    required this.poseFrames,
    required this.poseDetectionRate,
    required this.repCount,
    required this.meanLatencyMs,
    required this.p50LatencyMs,
    required this.p95LatencyMs,
    required this.minLatencyMs,
    required this.maxLatencyMs,
    required this.averageFps,
    required this.deviceManufacturer,
    required this.deviceModel,
    required this.androidVersion,
    required this.startedAtEpochMs,
    required this.finishedAtEpochMs,
  });

  Map<String, dynamic> toJson() => {
    'model': model,
    'duration_ms': durationMs,
    'total_frames': totalFrames,
    'pose_frames': poseFrames,
    'pose_detection_rate': double.parse(poseDetectionRate.toStringAsFixed(4)),
    'rep_count': repCount,
    'mean_latency_ms': double.parse(meanLatencyMs.toStringAsFixed(2)),
    'p50_latency_ms': double.parse(p50LatencyMs.toStringAsFixed(2)),
    'p95_latency_ms': double.parse(p95LatencyMs.toStringAsFixed(2)),
    'min_latency_ms': double.parse(minLatencyMs.toStringAsFixed(2)),
    'max_latency_ms': double.parse(maxLatencyMs.toStringAsFixed(2)),
    'average_fps': double.parse(averageFps.toStringAsFixed(2)),
    'device_manufacturer': deviceManufacturer,
    'device_model': deviceModel,
    'android_version': androidVersion,
    'started_at_epoch_ms': startedAtEpochMs,
    'finished_at_epoch_ms': finishedAtEpochMs,
  };
}
