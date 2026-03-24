# Plan: Exercise Type Selection + Full Alignment

## Context

The app works but is not aligned as a cohesive product:
- No exercise selection UI — bicep curl logic is invisibly hardcoded in `BenchmarkEngine`
- `CurlStage` / `elbowAngle` naming is curl-specific throughout all models
- ML Kit's 33-keypoint BlazePose uses **different joint indices** than COCO-17 (MoveNet/YOLO), so the elbow angle calculation is currently **wrong for ML Kit** (shoulder index 5 in COCO = nose in BlazePose)
- `HomeScreen` is missing the exercise selection step

The goal: add an **Exercise Type** selection (Bicep Curl only for now) on `HomeScreen`, wire it end-to-end, fix ML Kit joint indices, and rename everything to be exercise-agnostic so all 3 models work correctly.

---

## Files to Modify

| File | Change |
|------|--------|
| `lib/models/benchmark_stats.dart` | Rename `CurlStage` → `ExerciseStage`; `elbowAngle` → `jointAngle` |
| `lib/screens/home_screen.dart` | Add `ExerciseType` enum + dropdown; pass to `BenchmarkScreen` |
| `lib/screens/benchmark_screen.dart` | Accept `exerciseType`; pass to engine; show in AppBar |
| `lib/engine/benchmark_engine.dart` | Accept `ExerciseType`; fix ML Kit joint indices; rename fields |
| `lib/widgets/metrics_overlay.dart` | Accept `exerciseType`; show exercise-aware angle label |

---

## Step 1 — `benchmark_stats.dart`

Rename `CurlStage` → `ExerciseStage` (values stay: `up`, `down`, `unknown`).

```dart
// BEFORE
enum CurlStage { up, down, unknown }
class BenchmarkStats {
  final CurlStage curlStage;
  final double? elbowAngle;
  String get stageLabel { switch (curlStage) { ... } }
}

// AFTER
enum ExerciseStage { up, down, unknown }
class BenchmarkStats {
  final ExerciseStage stage;
  final double? jointAngle;
  String get stageLabel { switch (stage) { ... } }
}
```

Update `BenchmarkStats.zero()` to use `ExerciseStage.unknown` and `jointAngle: null`.

---

## Step 2 — `home_screen.dart`

Add `ExerciseType` enum with a label extension (place at top of `home_screen.dart`):

```dart
enum ExerciseType { bicepCurl }

extension ExerciseTypeLabel on ExerciseType {
  String get label => switch (this) {
    ExerciseType.bicepCurl => 'Bicep Curl',
  };
}
```

Add state field `ExerciseType _selectedExercise = ExerciseType.bicepCurl;`.

Add a second dropdown below the model dropdown, matching the same container style:
```
const Text('Select Exercise', style: ...)
Container > DropdownButton<ExerciseType>
```

Update `_navigateToBenchmark(source)` to pass `exercise: _selectedExercise` to `BenchmarkScreen`.

---

## Step 3 — `benchmark_screen.dart`

Add `final ExerciseType exerciseType;` to `BenchmarkScreen` constructor.

Change engine construction:
```dart
_engine = BenchmarkEngine(_service, widget.exerciseType);
```

Update AppBar title:
```dart
title: Text('${widget.model.label} — ${widget.exerciseType.label}'),
```

Pass `exerciseType` to `MetricsOverlay`:
```dart
MetricsOverlay(
  ...
  exerciseType: widget.exerciseType,
)
```

---

## Step 4 — `benchmark_engine.dart`

Constructor change:
```dart
BenchmarkEngine(this.service, this.exerciseType);
final ExerciseType exerciseType;
```

Rename internal fields: `_curlStage` → `_stage`, keep `_repCount` and `_angleSmoothingBuffer`.

Fix `_calculateElbowAngle` to branch by keypoint count (33 = BlazePose/ML Kit, 17 = COCO):

```dart
double? _calculateElbowAngle(List<PoseLandmark> lms) {
  if (service.keypointCount == 33) {
    // BlazePose indices: left shoulder=11, elbow=13, wrist=15 / right=12,14,16
    final l = _getAngle(lms, 11, 13, 15);
    final r = _getAngle(lms, 12, 14, 16);
    return (l != null && r != null) ? (l + r) / 2 : l ?? r;
  } else {
    // COCO-17 indices: left shoulder=5, elbow=7, wrist=9 / right=6,8,10
    final l = _getAngle(lms, 5, 7, 9);
    final r = _getAngle(lms, 6, 8, 10);
    return (l != null && r != null) ? (l + r) / 2 : l ?? r;
  }
}
```

Replace `_processRep` call in `_computeStats` with an exercise dispatch:
```dart
void _dispatchRepLogic(double angle) {
  switch (exerciseType) {
    case ExerciseType.bicepCurl:
      _processBicepCurl(angle); // existing logic, unchanged thresholds
  }
}
```

Update `_computeStats` return:
```dart
BenchmarkStats(
  ...
  stage: _stage,
  jointAngle: elbowAngle,
)
```

Update `reset()` to use `_stage = ExerciseStage.unknown`.

---

## Step 5 — `metrics_overlay.dart`

Add `exerciseType` parameter. Change the angle label row:

```dart
_metricRow(_angleLabel(), stats.jointAngle != null ? '${stats.jointAngle!.toStringAsFixed(1)}°' : '--', Colors.yellowAccent),

String _angleLabel() => switch (exerciseType) {
  ExerciseType.bicepCurl => 'Elbow°',
};
```

Change `stats.elbowAngle` → `stats.jointAngle` and `stats.curlStage` → `stats.stage` throughout.

---

## ML Kit Joint Index Fix (Critical)

Current COCO indices used: shoulder 5/6, elbow 7/8, wrist 9/10.
In BlazePose (ML Kit), index 5 = **left shoulder** ✓... wait — actually BlazePose uses:
- 11 = left shoulder, 13 = left elbow, 15 = left wrist
- 12 = right shoulder, 14 = right elbow, 16 = right wrist

COCO-17 uses:
- 5 = left shoulder, 7 = left elbow, 9 = left wrist
- 6 = right shoulder, 8 = right elbow, 10 = right wrist

The `service.keypointCount` check (33 vs 17) is the cleanest branch point since it's already on the abstract interface.

---

## Verification

1. Build and run on device/emulator — no compile errors.
2. `HomeScreen` shows two dropdowns: "Select Pose Model" and "Select Exercise".
3. For each of the 3 models + Bicep Curl + Live Camera:
   - AppBar shows `"<Model> — Bicep Curl"`
   - Perform a curl — Stage shows DOWN → UP, Reps increments by 1
   - `MetricsOverlay` shows "Elbow°" with a live degree reading (not `--`)
4. Upload Video + any model:
   - Frames display immediately (no spinner) — previously fixed
   - Reps/Angle update as video plays
5. All `CurlStage` references removed — no stale compile warnings.
