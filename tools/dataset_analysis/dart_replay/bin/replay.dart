// Phase E — Replay extracted MediaPipe keypoints through the real RepCounter.
//
// The FSM is the single source of truth for rep counting. Rather than port it
// to Python (which would inevitably drift), we pull the app package in via a
// local path dependency, wrap each JSONL frame into a PoseResult, feed the
// stream through RepCounter, and compare detected reps against manual
// annotations to compute precision / recall / F1 per clip.
//
// Usage:
//   dart run bin/replay.dart \
//       --keypoints ../data/keypoints \
//       --videos    ../data/annotations/videos.csv \
//       --reps      ../data/annotations/reps.csv \
//       --out       ../data/derived/validation_report.md
//
// Every input is defaulted to the repo-relative dataset paths so the plain
// `dart run bin/replay.dart` invocation Just Works once the dataset exists.

import 'dart:convert';
import 'dart:io';

import 'package:fitrack/core/types.dart';
import 'package:fitrack/models/pose_landmark.dart';
import 'package:fitrack/models/pose_result.dart';

// Intentionally imported but scoped behind a typedef so the public surface of
// this harness doesn't leak engine internals — a future refactor can swap the
// counter out for a test-harness variant without touching call sites.
import 'package:fitrack/engine/rep_counter.dart' as engine;

const _defaultKeypointsDir = '../data/keypoints';
const _defaultVideosCsv = '../data/annotations/videos.csv';
const _defaultRepsCsv = '../data/annotations/reps.csv';
const _defaultOutMarkdown = '../data/derived/validation_report.md';

/// A rep boundary as reported by the FSM while replaying a clip.
class DetectedRep {
  final int indexInClip;
  final int endFrame;
  final int endTimestampMs;

  const DetectedRep({
    required this.indexInClip,
    required this.endFrame,
    required this.endTimestampMs,
  });
}

/// Manual annotation row. Mirrors reps.csv from compute_rep_stats.py.
class AnnotatedRep {
  final String clipId;
  final int repIdx;
  final int startFrame;
  final int peakFrame;
  final int endFrame;
  final String quality;

  const AnnotatedRep({
    required this.clipId,
    required this.repIdx,
    required this.startFrame,
    required this.peakFrame,
    required this.endFrame,
    required this.quality,
  });
}

class VideoMeta {
  final String clipId;
  final String arm;
  final int fps;

  const VideoMeta({required this.clipId, required this.arm, required this.fps});
}

class ClipReport {
  final String clipId;
  final int annotatedCount;
  final int detectedCount;
  final int truePositives;
  final int falsePositives;
  final int falseNegatives;

  const ClipReport({
    required this.clipId,
    required this.annotatedCount,
    required this.detectedCount,
    required this.truePositives,
    required this.falsePositives,
    required this.falseNegatives,
  });

  double get precision => (truePositives + falsePositives) == 0
      ? 0.0
      : truePositives / (truePositives + falsePositives);

  double get recall => (truePositives + falseNegatives) == 0
      ? 0.0
      : truePositives / (truePositives + falseNegatives);

  double get f1 => (precision + recall) == 0
      ? 0.0
      : 2 * precision * recall / (precision + recall);
}

Future<int> main(List<String> args) async {
  final opts = _parseArgs(args);

  if (!File(opts.videosCsv).existsSync()) {
    stderr.writeln('error: videos.csv not found at ${opts.videosCsv}');
    return 2;
  }
  if (!File(opts.repsCsv).existsSync()) {
    stderr.writeln('error: reps.csv not found at ${opts.repsCsv}');
    return 2;
  }
  if (!Directory(opts.keypointsDir).existsSync()) {
    stderr.writeln(
      'error: keypoints directory not found at ${opts.keypointsDir}',
    );
    return 2;
  }

  final videos = _readVideos(File(opts.videosCsv));
  final reps = _readReps(File(opts.repsCsv));

  if (reps.isEmpty) {
    stderr.writeln(
      'No annotated reps found. Replay is a no-op until '
      '${opts.repsCsv} is populated. Writing an empty report.',
    );
    await _writeReport(opts.outMarkdown, const []);
    return 0;
  }

  final byClip = <String, List<AnnotatedRep>>{};
  for (final rep in reps) {
    byClip.putIfAbsent(rep.clipId, () => []).add(rep);
  }

  final clipReports = <ClipReport>[];
  for (final entry in byClip.entries) {
    final clipId = entry.key;
    final meta = videos[clipId];
    if (meta == null) {
      stderr.writeln(
        'warning: reps.csv references clip_id "$clipId" '
        'not found in videos.csv — skipping',
      );
      continue;
    }
    final jsonl = File('${opts.keypointsDir}/$clipId.jsonl');
    if (!jsonl.existsSync()) {
      stderr.writeln(
        'warning: keypoints file missing for "$clipId" (${jsonl.path}) — skipping',
      );
      continue;
    }
    final detected = await _replayClip(jsonl, meta);
    final report = _scoreClip(clipId, entry.value, detected);
    clipReports.add(report);
  }

  await _writeReport(opts.outMarkdown, clipReports);
  stderr.writeln('Wrote validation report -> ${opts.outMarkdown}');
  return 0;
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------

class _Opts {
  final String keypointsDir;
  final String videosCsv;
  final String repsCsv;
  final String outMarkdown;

  _Opts({
    required this.keypointsDir,
    required this.videosCsv,
    required this.repsCsv,
    required this.outMarkdown,
  });
}

_Opts _parseArgs(List<String> args) {
  String keypoints = _defaultKeypointsDir;
  String videos = _defaultVideosCsv;
  String reps = _defaultRepsCsv;
  String out = _defaultOutMarkdown;
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    final next = i + 1 < args.length ? args[i + 1] : null;
    switch (flag) {
      case '--keypoints':
        if (next == null) _die('--keypoints requires a value');
        keypoints = next;
        i++;
        break;
      case '--videos':
        if (next == null) _die('--videos requires a value');
        videos = next;
        i++;
        break;
      case '--reps':
        if (next == null) _die('--reps requires a value');
        reps = next;
        i++;
        break;
      case '--out':
        if (next == null) _die('--out requires a value');
        out = next;
        i++;
        break;
      case '-h':
      case '--help':
        _printHelp();
        exit(0);
      default:
        _die('unknown argument: $flag');
    }
  }
  return _Opts(
    keypointsDir: keypoints,
    videosCsv: videos,
    repsCsv: reps,
    outMarkdown: out,
  );
}

Never _die(String msg) {
  stderr.writeln('error: $msg');
  _printHelp();
  exit(2);
}

void _printHelp() {
  stderr.writeln(
    'Usage: dart run bin/replay.dart [--keypoints DIR] '
    '[--videos CSV] [--reps CSV] [--out MD]',
  );
}

// ---------------------------------------------------------------------------
// CSV readers — minimal, no csv package to keep the dependency surface tiny.
// ---------------------------------------------------------------------------

Map<String, VideoMeta> _readVideos(File file) {
  final lines = file.readAsLinesSync();
  if (lines.isEmpty) return const {};
  final header = _splitCsv(lines.first);
  final idxClip = header.indexOf('clip_id');
  final idxArm = header.indexOf('arm');
  final idxFps = header.indexOf('fps');
  if (idxClip < 0 || idxArm < 0 || idxFps < 0) {
    stderr.writeln(
      'error: videos.csv missing required columns (clip_id, arm, fps)',
    );
    exit(2);
  }
  final out = <String, VideoMeta>{};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final row = _splitCsv(line);
    final clipId = row[idxClip].trim();
    out[clipId] = VideoMeta(
      clipId: clipId,
      arm: row[idxArm].trim().toLowerCase(),
      fps: int.parse(row[idxFps].trim()),
    );
  }
  return out;
}

List<AnnotatedRep> _readReps(File file) {
  final lines = file.readAsLinesSync();
  if (lines.isEmpty) return const [];
  final header = _splitCsv(lines.first);
  int col(String name) {
    final i = header.indexOf(name);
    if (i < 0) {
      stderr.writeln('error: reps.csv missing required column "$name"');
      exit(2);
    }
    return i;
  }

  final ic = col('clip_id');
  final iidx = col('rep_idx');
  final ist = col('start_frame');
  final ip = col('peak_frame');
  final iend = col('end_frame');
  final iq = col('quality');
  final out = <AnnotatedRep>[];
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final row = _splitCsv(line);
    out.add(
      AnnotatedRep(
        clipId: row[ic].trim(),
        repIdx: int.parse(row[iidx].trim()),
        startFrame: int.parse(row[ist].trim()),
        peakFrame: int.parse(row[ip].trim()),
        endFrame: int.parse(row[iend].trim()),
        quality: row[iq].trim().toLowerCase(),
      ),
    );
  }
  return out;
}

List<String> _splitCsv(String line) {
  // Simple splitter — we control the CSV source so no embedded quoting.
  return line.split(',');
}

// ---------------------------------------------------------------------------
// Replay — feeds JSONL frames through the FSM.
// ---------------------------------------------------------------------------

Future<List<DetectedRep>> _replayClip(File jsonl, VideoMeta meta) async {
  final counter = engine.RepCounter(
    exercise: ExerciseType.bicepsCurl,
    side: _sideFromArm(meta.arm),
  );

  final detected = <DetectedRep>[];
  int lastReps = 0;

  // Pump the first `setupWarmupFrames` frames through `updateSetupView` so
  // the curl view-detector locks before any `update()` call. Invariant 9:
  // curl drops rep commits while view is unknown, so without this warm-up
  // the replay harness would report 0 reps on every clip regardless of FSM
  // behavior. 30 frames comfortably exceeds `kViewDetectionConsensusFrames`
  // (10) so any clip with a stable opening pose will lock.
  const setupWarmupFrames = 30;
  var warmupFrames = 0;

  final lines = jsonl
      .openRead()
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  var frameCounter = 0;
  var lastTMs = 0;
  await for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final obj = jsonDecode(trimmed) as Map<String, dynamic>;
    final frame = (obj['frame'] as num).toInt();
    final tMs = (obj['t_ms'] as num).toInt();
    final landmarksRaw = obj['landmarks'] as List<dynamic>;
    final landmarks = <PoseLandmark>[];
    for (var i = 0; i < landmarksRaw.length; i++) {
      final entry = landmarksRaw[i] as Map<String, dynamic>;
      landmarks.add(
        PoseLandmark(
          type: i,
          x: (entry['x'] as num).toDouble(),
          y: (entry['y'] as num).toDouble(),
          confidence: (entry['v'] as num).toDouble(),
        ),
      );
    }
    final pose = PoseResult(landmarks: landmarks, inferenceTime: Duration.zero);

    // Warm up the view detector on the first N frames.
    if (warmupFrames < setupWarmupFrames) {
      warmupFrames++;
      counter.updateSetupView(pose);
      if (warmupFrames < setupWarmupFrames) continue;
      // Final warmup frame: fall through into the replay path for this
      // same pose so no frame is double-counted nor skipped.
    }

    final snapshot = counter.update(pose);
    if (snapshot.reps > lastReps) {
      detected.add(
        DetectedRep(
          indexInClip: snapshot.reps,
          endFrame: frame,
          endTimestampMs: tMs,
        ),
      );
      lastReps = snapshot.reps;
    }
    frameCounter = frame;
    lastTMs = tMs;
  }
  // Unused now, but kept for future per-clip telemetry.
  _silence(frameCounter);
  _silence(lastTMs);
  return detected;
}

ExerciseSide _sideFromArm(String arm) {
  switch (arm) {
    case 'left':
      return ExerciseSide.left;
    case 'right':
      return ExerciseSide.right;
    case 'both':
      return ExerciseSide.both;
    default:
      return ExerciseSide.right;
  }
}

void _silence(Object? _) {}

// ---------------------------------------------------------------------------
// Scoring — overlap-based TP/FP/FN per clip.
// ---------------------------------------------------------------------------

ClipReport _scoreClip(
  String clipId,
  List<AnnotatedRep> annotated,
  List<DetectedRep> detected,
) {
  // A detected rep matches an annotated rep when its endFrame falls within
  // the annotated [startFrame, endFrame] window. We greedy-match in order so
  // each annotation pairs with at most one detection.
  final usedDetected = <int>{};
  var tp = 0;
  for (final ann in annotated) {
    for (var i = 0; i < detected.length; i++) {
      if (usedDetected.contains(i)) continue;
      final det = detected[i];
      if (det.endFrame >= ann.startFrame && det.endFrame <= ann.endFrame) {
        tp++;
        usedDetected.add(i);
        break;
      }
    }
  }
  final fp = detected.length - usedDetected.length;
  final fn = annotated.length - tp;
  return ClipReport(
    clipId: clipId,
    annotatedCount: annotated.length,
    detectedCount: detected.length,
    truePositives: tp,
    falsePositives: fp,
    falseNegatives: fn,
  );
}

// ---------------------------------------------------------------------------
// Markdown report
// ---------------------------------------------------------------------------

Future<void> _writeReport(String path, List<ClipReport> reports) async {
  final f = File(path);
  await f.parent.create(recursive: true);
  final buf = StringBuffer();
  buf.writeln('# Replay validation report');
  buf.writeln();
  buf.writeln(
    'Generated by `tools/dataset_analysis/dart_replay/bin/replay.dart`.',
  );
  buf.writeln();
  if (reports.isEmpty) {
    buf.writeln('_No annotated reps found — nothing to validate._');
    await f.writeAsString(buf.toString());
    return;
  }
  var totalAnn = 0;
  var totalDet = 0;
  var totalTp = 0;
  var totalFp = 0;
  var totalFn = 0;
  buf.writeln(
    '| clip | annotated | detected | TP | FP | FN | precision | recall | F1 |',
  );
  buf.writeln(
    '|------|-----------|----------|----|----|----|-----------|--------|-----|',
  );
  for (final r in reports) {
    buf.writeln(
      '| ${r.clipId} | ${r.annotatedCount} | ${r.detectedCount} | '
      '${r.truePositives} | ${r.falsePositives} | ${r.falseNegatives} | '
      '${r.precision.toStringAsFixed(3)} | ${r.recall.toStringAsFixed(3)} | '
      '${r.f1.toStringAsFixed(3)} |',
    );
    totalAnn += r.annotatedCount;
    totalDet += r.detectedCount;
    totalTp += r.truePositives;
    totalFp += r.falsePositives;
    totalFn += r.falseNegatives;
  }
  final totalPrec = (totalTp + totalFp) == 0
      ? 0.0
      : totalTp / (totalTp + totalFp);
  final totalRec = (totalTp + totalFn) == 0
      ? 0.0
      : totalTp / (totalTp + totalFn);
  final totalF1 = (totalPrec + totalRec) == 0
      ? 0.0
      : 2 * totalPrec * totalRec / (totalPrec + totalRec);
  buf.writeln(
    '| **ALL** | $totalAnn | $totalDet | $totalTp | $totalFp | $totalFn | '
    '${totalPrec.toStringAsFixed(3)} | ${totalRec.toStringAsFixed(3)} | '
    '${totalF1.toStringAsFixed(3)} |',
  );
  await f.writeAsString(buf.toString());
}
