# Plan: Add ML Kit Full (Accurate) Model Option

## Context

The app currently has one ML Kit option which uses BlazePose Lite (`PoseDetectionModel.base` — the default when no model is specified). The user wants to add a second ML Kit option using BlazePose Full (`PoseDetectionModel.accurate`) for higher accuracy, while keeping the Lite option as well.

The dropdown in `home_screen.dart` is driven by `PoseModel.values` automatically, so adding a new enum value is all that's needed for the UI.

---

## Files to Modify

### 1. `lib/screens/home_screen.dart`

**Add `mlkitFull` to the `PoseModel` enum:**
```dart
enum PoseModel { mlkit, mlkitFull, movenet, yoloPose }
```

**Add its label in the extension:**
```dart
case PoseModel.mlkitFull:
  return 'ML Kit Full';
```

The dropdown (`PoseModel.values.map(...)` at line 84) will automatically include the new option — no other UI changes needed.

### 2. `lib/services/mlkit_pose_service.dart`

**Add a constructor parameter for the model variant:**
```dart
class MLKitPoseService extends PoseEstimatorService {
  final bool useAccurateModel;

  MLKitPoseService({this.useAccurateModel = false});

  @override
  String get name => useAccurateModel ? 'ML Kit Full' : 'ML Kit Lite';

  @override
  Future<void> initialize() async {
    _detector = PoseDetector(
      options: PoseDetectorOptions(
        model: useAccurateModel
            ? PoseDetectionModel.accurate
            : PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }
```

### 3. `lib/screens/benchmark_screen.dart`

**Update `_createService()` to handle the new enum value:**
```dart
PoseEstimatorService _createService() {
  switch (widget.model) {
    case PoseModel.mlkit:
      return MLKitPoseService();
    case PoseModel.mlkitFull:
      return MLKitPoseService(useAccurateModel: true);
    case PoseModel.movenet:
      return MoveNetService();
    case PoseModel.yoloPose:
      return YoloPoseService();
  }
}
```

**Update the `_service is MLKitPoseService` check** (line ~146) — this already works for both since both return an `MLKitPoseService` instance. No change needed there.

---

## Critical Files

| File | Change |
|------|--------|
| `lib/screens/home_screen.dart` | Add `mlkitFull` enum value + label |
| `lib/services/mlkit_pose_service.dart` | Add `useAccurateModel` param, update `name`, set `PoseDetectionModel` |
| `lib/screens/benchmark_screen.dart` | Add `mlkitFull` case in `_createService()` |

---

## Verification

1. Run the app
2. Open the model dropdown — should show 4 options: ML Kit Lite, ML Kit Full, MoveNet Lightning, YOLO-Pose
3. Select "ML Kit Full" → start live camera → confirm skeleton draws on body
4. Check the metrics overlay shows "ML Kit Full" as the model name
5. Confirm "ML Kit Lite" still works correctly (no regression)
6. Compare FPS between Lite and Full — Full should be noticeably slower (~2x latency)
