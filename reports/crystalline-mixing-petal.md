# Plan: Exercise-Specific Skeleton Filtering for Bicep Curl

## Context
After getting YOLO26n-Pose and MoveNet skeletons visible, the user wants to visually filter the skeleton overlay so that only the keypoints and bone connections **mathematically used in bicep curl tracking** are rendered. All irrelevant body parts (head, torso, hips, legs) must be hidden, keeping the UI focused and informative.

---

## Bicep Curl Relevant Keypoints

### COCO-17 (MoveNet + YOLO26n-Pose)
| Index | Name |
|-------|------|
| 5 | left_shoulder |
| 6 | right_shoulder |
| 7 | left_elbow |
| 8 | right_elbow |
| 9 | left_wrist |
| 10 | right_wrist |

Relevant connections: `[5,6], [5,7], [7,9], [6,8], [8,10]`

### ML Kit BlazePose (33 keypoints)
| Index | Name |
|-------|------|
| 11 | left_shoulder |
| 12 | right_shoulder |
| 13 | left_elbow |
| 14 | right_elbow |
| 15 | left_wrist |
| 16 | right_wrist |

Relevant connections: `[11,12], [11,13], [13,15], [12,14], [14,16]`

---

## Changes

### 1. `lib/utils/skeleton_connections.dart`
Add two new filtered constant lists:

```dart
/// COCO-17: connections used for bicep curl tracking only
const List<List<int>> bicepCurlSkeletonConnections = [
  [5, 6], // shoulders
  [5, 7], [7, 9], // left arm
  [6, 8], [8, 10], // right arm
];

/// COCO-17: keypoint indices used for bicep curl
const Set<int> bicepCurlKeypoints = {5, 6, 7, 8, 9, 10};

/// ML Kit BlazePose: connections used for bicep curl tracking only
const List<List<int>> mlkitBicepCurlSkeletonConnections = [
  [11, 12], // shoulders
  [11, 13], [13, 15], // left arm
  [12, 14], [14, 16], // right arm
];

/// ML Kit BlazePose: keypoint indices used for bicep curl
const Set<int> mlkitBicepCurlKeypoints = {11, 12, 13, 14, 15, 16};
```

### 2. `lib/widgets/skeleton_painter.dart`
- Add `exerciseType` parameter (nullable, typed as `ExerciseType` from `home_screen.dart`)
- Add import for `home_screen.dart` (for `ExerciseType`) and `skeleton_connections.dart` additions
- In `paint()`: when `exerciseType == ExerciseType.bicepCurl`, use the filtered connection/keypoint sets instead of the full ones

```dart
import '../screens/home_screen.dart'; // for ExerciseType

class SkeletonPainter extends CustomPainter {
  final List<PoseLandmark> landmarks;
  final double confidenceThreshold;
  final double? aspectRatio;
  final ExerciseType? exerciseType; // NEW

  SkeletonPainter({
    required this.landmarks,
    this.confidenceThreshold = 0.05,
    this.aspectRatio,
    this.exerciseType, // NEW
  });
```

In `paint()`, replace the connections selection block:
```dart
// Existing:
final connections = landmarks.length > 17 ? mlkitSkeletonConnections : skeletonConnections;

// New:
final bool isMLKit = landmarks.length > 17;
final List<List<int>> connections;
final Set<int>? allowedKeypoints;
if (exerciseType == ExerciseType.bicepCurl) {
  connections = isMLKit ? mlkitBicepCurlSkeletonConnections : bicepCurlSkeletonConnections;
  allowedKeypoints = isMLKit ? mlkitBicepCurlKeypoints : bicepCurlKeypoints;
} else {
  connections = isMLKit ? mlkitSkeletonConnections : skeletonConnections;
  allowedKeypoints = null; // show all
}
```

Then in the keypoints loop, add a guard:
```dart
for (final lm in landmarks) {
  if (allowedKeypoints != null && !allowedKeypoints.contains(lm.type)) continue; // NEW
  if (lm.confidence < confidenceThreshold) continue;
  // ... rest of drawing
}
```

Update `shouldRepaint`:
```dart
bool shouldRepaint(SkeletonPainter oldDelegate) =>
  landmarks != oldDelegate.landmarks || exerciseType != oldDelegate.exerciseType;
```

### 3. `lib/screens/benchmark_screen.dart`
Pass `widget.exerciseType` to `SkeletonPainter` (line ~402):

```dart
CustomPaint(
  painter: SkeletonPainter(
    landmarks: _landmarks,
    aspectRatio: ...,
    exerciseType: widget.exerciseType, // NEW
  ),
  size: Size.infinite,
),
```

---

## Critical Files
- `lib/utils/skeleton_connections.dart` — add filtered connection/keypoint constants
- `lib/widgets/skeleton_painter.dart` — add `exerciseType` param, filter keypoints and bones
- `lib/screens/benchmark_screen.dart` — pass `widget.exerciseType` to painter

---

## Verification
1. Run with MoveNet + bicep curl → only shoulders, elbows, wrists visible; no head/torso/legs
2. Run with YOLO + bicep curl → same filtered skeleton
3. Run with ML Kit + bicep curl → BlazePose filtered skeleton (indices 11–16)
4. All three models: rep counter still works correctly (engine uses same keypoint indices, unchanged)
