import 'dart:convert';
import 'dart:io';
import 'package:csv/csv.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import '../models/benchmark_stats.dart';
import '../models/pose_result.dart';
import '../models/session_summary.dart';

class AnalyticsService {
  final String modelName;
  final int startTimeMs;
  
  final List<List<dynamic>> _frameLogs = [];
  final List<double> _allLatencies = [];
  int _poseFrames = 0;
  int _totalReps = 0;

  AnalyticsService({required this.modelName}) 
    : startTimeMs = DateTime.now().millisecondsSinceEpoch {
    // CSV Header
    _frameLogs.add([
      'relative_timestamp_ms',
      'latency_ms',
      'pose_found',
      'rep_count',
      'stage',
      'representative_angle_deg',
      'avg_confidence',
      'keypoint_count',
      'rolling_fps'
    ]);
  }

  void logFrame(PoseResult result, BenchmarkStats stats) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final relTime = now - startTimeMs;
    
    final bool poseFound = result.landmarks.isNotEmpty;
    if (poseFound) _poseFrames++;
    _totalReps = stats.repCount;
    _allLatencies.add(stats.latencyMs);

    double avgConf = 0;
    if (poseFound) {
      avgConf = result.landmarks.map((l) => l.confidence).reduce((a, b) => a + b) / result.landmarks.length;
    }

    _frameLogs.add([
      relTime,
      double.parse(stats.latencyMs.toStringAsFixed(2)),
      poseFound ? 1 : 0,
      stats.repCount,
      stats.stageLabel,
      stats.jointAngle != null ? double.parse(stats.jointAngle!.toStringAsFixed(1)) : '',
      double.parse(avgConf.toStringAsFixed(3)),
      result.landmarks.length,
      double.parse(stats.rollingFps.toStringAsFixed(1))
    ]);
  }

  Future<String> exportCsv() async {
    final String csv = ListToCsvConverter().convert(_frameLogs);
    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'session_${modelName}_$startTimeMs.csv';
    final file = File('${directory.path}/$fileName');
    await file.writeAsString(csv);
    return file.path;
  }

  Future<SessionSummary> generateSummary() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final duration = now - startTimeMs;
    final totalFrames = _frameLogs.length - 1; // subtract header

    // Latency Calcs
    _allLatencies.sort();
    final double mean = _allLatencies.isEmpty ? 0 : _allLatencies.reduce((a, b) => a + b) / _allLatencies.length;
    final double min = _allLatencies.isEmpty ? 0 : _allLatencies.first;
    final double max = _allLatencies.isEmpty ? 0 : _allLatencies.last;
    final double p50 = _allLatencies.isEmpty ? 0 : _allLatencies[(_allLatencies.length * 0.5).floor()];
    final double p95 = _allLatencies.isEmpty ? 0 : _allLatencies[(_allLatencies.length * 0.95).floor()];

    // Device Info
    final deviceInfo = DeviceInfoPlugin();
    String manufacturer = 'Unknown';
    String model = 'Unknown';
    String version = 'Unknown';

    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      manufacturer = androidInfo.manufacturer;
      model = androidInfo.model;
      version = androidInfo.version.release;
    }

    return SessionSummary(
      model: modelName,
      durationMs: duration,
      totalFrames: totalFrames,
      poseFrames: _poseFrames,
      poseDetectionRate: totalFrames > 0 ? _poseFrames / totalFrames : 0,
      repCount: _totalReps,
      meanLatencyMs: mean,
      p50LatencyMs: p50,
      p95LatencyMs: p95,
      minLatencyMs: min,
      maxLatencyMs: max,
      averageFps: duration > 0 ? (totalFrames * 1000.0 / duration) : 0,
      deviceManufacturer: manufacturer,
      deviceModel: model,
      androidVersion: version,
      startedAtEpochMs: startTimeMs,
      finishedAtEpochMs: now,
    );
  }

  Future<String> exportJson(SessionSummary summary) async {
    final jsonStr = jsonEncode(summary.toJson());
    final directory = await getApplicationDocumentsDirectory();
    final fileName = 'summary_${modelName}_$startTimeMs.json';
    final file = File('${directory.path}/$fileName');
    await file.writeAsString(jsonStr);
    return file.path;
  }
}
