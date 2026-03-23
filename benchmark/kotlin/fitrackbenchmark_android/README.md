# FitTrack Benchmark Android

This project is a native Android benchmark harness for on-device human pose estimation models.

Implemented models:
- ML Kit Fast
- ML Kit Accurate
- MoveNet Lightning
- MoveNet Thunder
- MediaPipe Pose Landmarker Lite

## What it does

- Uses CameraX with the front camera.
- Draws a skeleton overlay aligned with the preview.
- Lets you choose a model from the UI.
- Runs a **60-second biceps curl benchmark**.
- Tracks curl reps using elbow angle.
- Saves:
  - a JSON summary
  - a per-frame CSV

## Saved result location on the phone

The app writes benchmark results to:

`Android/data/com.messi.fitrackbenchmark/files/Documents/benchmarks/`

You cannot write directly into your computer project folder from an Android phone app at runtime. The practical workflow is:

1. Run the benchmark on the phone.
2. Pull the files into your computer repo with Android Studio Device Explorer or ADB.

Example ADB command:

```bash
adb pull /sdcard/Android/data/com.messi.fitrackbenchmark/files/Documents/benchmarks ./benchmarks
```

Depending on device / Android version, Android Studio Device Explorer is often the simplest option.

## How model assets are handled

The Gradle task `downloadPoseModels` runs automatically before build and downloads:

- `movenet_singlepose_lightning_int8_4.tflite`
- `movenet_singlepose_thunder_int8_4.tflite`
- `pose_landmarker_lite.task`

If you prefer manual asset management, place those files into:

`app/src/main/assets/`

## Notes

- The camera preview uses `FIT_CENTER`, and the overlay uses the same fit-center math so the skeleton lines up with the image.
- The phone-facing preview is mirrored in the overlay to match the front camera UX.
- For repeatable academic comparison, all engines receive the same upright bitmap frame from the analyzer.
- This means the reported latency includes the real app-side preprocessing path.

## Expected next improvements

- Add GPU delegate toggles for MoveNet and MediaPipe.
- Add repeated benchmark runs and aggregate comparison screens.
- Export benchmark history inside the app.
- Add prerecorded video benchmark mode for stricter repeatability.
