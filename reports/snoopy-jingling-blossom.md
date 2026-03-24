# FiTrack Pose Estimation Benchmark App — Implementation Plan

## Context
Building a Flutter benchmark app to compare pose estimation models (ML Kit, MoveNet Lightning, YOLO-Pose) on Android emulator. The project directory is empty — we scaffold from scratch with `flutter create`.

---

## Step 0: Project Scaffolding & Configuration
- Run `flutter create . --platforms android` in the project directory
- Set `minSdkVersion 21`, `compileSdkVersion 34` in `android/app/build.gradle`
- Add `noCompress 'tflite'` in aaptOptions
- Add camera + internet permissions to `AndroidManifest.xml`

## Step 1: Dependencies (`pubspec.yaml`)
```
camera, image_picker, video_player,
google_mlkit_pose_detection, tflite_flutter, path_provider
```
Add TFLite model assets under `assets/models/`.

## Step 2: File Structure
```
lib/
  main.dart / app.dart
  models/
    pose_landmark.dart        # Normalized landmark (x, y, confidence, type)
    pose_result.dart          # List<PoseLandmark> + inferenceTime
    benchmark_stats.dart      # FPS, latency, jitter data class
  services/
    pose_estimator_service.dart  # Abstract: initialize(), processFrame(), dispose()
    mlkit_pose_service.dart      # google_mlkit_pose_detection
    movenet_service.dart         # tflite_flutter, 192x192 input, 17 keypoints
    yolo_pose_service.dart       # tflite_flutter, 256x256 input, 17 keypoints
    frame_extractor_service.dart # Video frame extraction via MethodChannel
  engine/
    benchmark_engine.dart     # Stopwatch, SMA(10) FPS, jitter calculation
  screens/
    home_screen.dart          # Model + source selection
    benchmark_screen.dart     # Camera/video feed + overlay + metrics
  widgets/
    skeleton_painter.dart     # CustomPainter for skeleton
    metrics_overlay.dart      # Live stats panel
  utils/
    image_converter.dart      # CameraImage YUV420 → NV21/RGB conversion
    skeleton_connections.dart  # COCO 17-keypoint bone pairs
```

## Step 3: Core Models
- **PoseLandmark**: `type`, `x`, `y`, `confidence` (normalized 0..1)
- **PoseResult**: `List<PoseLandmark>` + `Duration inferenceTime`
- **BenchmarkStats**: `avgFps`, `latencyMs`, `stabilityJitter`

## Step 4: Abstract Service Interface
```dart
abstract class PoseEstimatorService {
  String get name;
  Future<void> initialize();
  Future<PoseResult> processFrame(Uint8List rgbBytes, int width, int height);
  void dispose();
}
```

## Step 5: Service Implementations

### MLKitPoseService
- Uses `PoseDetector` with stream mode
- Accepts NV21 bytes directly from camera via `InputImage.fromBytes()`
- Maps `PoseLandmarkType` to normalized coordinates

### MoveNetService
- Loads `movenet_lightning.tflite` (int8, 192x192 input)
- Output: `[1,1,17,3]` → 17 COCO keypoints (y, x, confidence)
- Resize + normalize input to uint8 RGB

### YoloPoseService
- Loads `yolo_pose.tflite` (float32, 256x256 input, normalized 0..1)
- Output: `[1,56,N]` → parse bbox + 17 keypoints per detection
- Take top-confidence detection

## Step 6: Image Converter (`utils/image_converter.dart`)
- `cameraImageToNv21()`: Concatenate Y+VU planes for ML Kit
- `cameraImageToRgb()`: YUV420→RGB with resize for TFLite models

## Step 7: Benchmark Engine
- Wrap `processFrame()` with `Stopwatch`
- **FPS**: SMA over last 10 inference times → `1000 / avgLatency`
- **Jitter**: Average Euclidean distance between same keypoint across consecutive frames (lower = more stable)

## Step 8: Skeleton Painter
- COCO skeleton connections (16 bone pairs)
- Color-coded by confidence: green (>0.7), yellow (>0.3), skip below 0.3
- Scale normalized coords to canvas size

## Step 9: Screens

### HomeScreen
- Dropdown: model selection
- Two buttons: Live Camera / Upload Video → navigate to BenchmarkScreen

### BenchmarkScreen
- **Live Camera**: `startImageStream()`, throttle with `_isProcessing` flag, overlay skeleton + metrics
- **Video**: `ImagePicker` → `FrameExtractorService` stream → run benchmark per frame

## Step 10: Video Frame Extraction (Method Channel)
- Android side: `MediaMetadataRetriever.getFrameAtTime()` → returns ARGB bytes
- Dart side: `MethodChannel('fitrack/video_frames')` calls `extractFrame(path, timeUs)`
- File: `android/app/src/main/kotlin/.../MainActivity.kt`

## Step 11: TFLite Model Files
- **MoveNet Lightning**: Download from TF Hub (int8, ~3MB)
- **YOLO-Pose**: Export via `ultralytics` Python (`yolo export model=yolov8n-pose.pt format=tflite`)
- Place in `assets/models/`

---

## Implementation Order
1. Scaffold + deps + android config
2. Data classes (`models/`)
3. Utils (image_converter, skeleton_connections)
4. Abstract service + MLKitPoseService
5. SkeletonPainter + MetricsOverlay widgets
6. BenchmarkEngine
7. HomeScreen + BenchmarkScreen (camera mode)
8. **Milestone: Live camera + ML Kit + overlay + metrics working**
9. MoveNetService + download tflite
10. YoloPoseService + export tflite
11. FrameExtractorService + Android MethodChannel
12. Video upload mode in BenchmarkScreen

## Key Gotchas
- Camera sensor rotated 90° on Android — pass correct rotation to ML Kit, physically rotate pixels for TFLite
- `tflite_flutter` `run()` is synchronous — blocks UI thread (acceptable for benchmarking accuracy)
- NV21 plane layout: check if `planes[0]` contains full NV21 buffer before concatenating
- Emulator webcam will have lower FPS than physical device

## Verification
1. Run `flutter build apk --debug` to verify compilation
2. Launch on emulator, grant camera permission
3. Test ML Kit with live camera — verify skeleton overlay draws correctly
4. Switch to MoveNet — compare FPS/latency numbers
5. Upload a video file — verify frame extraction and benchmark stats
6. Confirm metrics panel updates in real-time with reasonable values
