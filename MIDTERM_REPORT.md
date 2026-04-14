# FiTrack Mid-Semester Progress Report

## 1. Problem and Our Solution

Many people work out alone without a coach and therefore do not receive immediate feedback about whether they are performing an exercise correctly. Video tutorials can demonstrate correct form, but they cannot observe the user and react during the movement itself. In practice this creates two problems: repetitions may be counted inaccurately by the user, and form mistakes may be repeated without correction.

Our project, **FiTrack**, addresses this problem with a mobile fitness assistant that uses the smartphone camera for on-device pose estimation. The system tracks body landmarks in real time, overlays a visual skeleton on the live camera feed, counts repetitions, and provides simple exercise-specific feedback cues. The current implemented architecture focuses on three base exercises: **biceps curl, squat, and push-up**. Among these, biceps curl currently has the richest analysis pipeline, while squat and push-up are already integrated at the prototype level.

At this stage, our project is still a prototype under active development. Even though there are many core systems that work more or less, the architecture of the application, user experience and performance may not be up to standarts. The main goal of the current phase has been to establish a reliable end-to-end mobile pipeline and validate that real-time coaching logic is feasible on-device.

## 2. Current Implemented Architecture

The current implemented architecture is a Flutter-based mobile application organized around four practical layers and those are Presentation, Service, Exercise Logic and Data/Model layer. These are open to changes.

### Benchmarking

Before starting implementation on Flutter, we have created two benchmark applications on Flutter and Kotlin using many models. Among those models, ML Kit Pose on Flutter seemed the most promising to us in terms of performance and applicability. These benchmark results were discussed in GitHub issue `#1` and helped us decide which direction was most practical for the current term project implementation.

#### Flutter Benchmark Results

| Model | Mean Latency | P50 (Median) | P95 Latency | Avg FPS | Detection Rate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **ML Kit Pose** | **19.38 ms** | **14.08 ms** | **37.43 ms** | **22.14** | 92.55% |
| ML Kit Full | 23.72 ms | 17.10 ms | 43.34 ms | 18.27 | 99.75% |
| MoveNet Lightning | 33.05 ms | 26.33 ms | 65.36 ms | 21.41 | 100.00% |
| YOLO26n-Pose | 126.64 ms | 111.63 ms | 239.41 ms | 6.86 | 96.83% |

Key observations from the Flutter benchmark were:

- **ML Kit Pose** achieved the best overall speed-efficiency balance, with the lowest mean latency and the highest average FPS.
- **MoveNet Lightning** achieved the highest detection coverage, but ML Kit remained more practical for the Flutter-based real-time prototype.
- **YOLO26n-Pose** was too slow in this setup to be a realistic real-time option.

For the Flutter branch of the project, these results strongly supported the decision to use **ML Kit Pose** as the primary backend in the current application.

#### Kotlin / Android Benchmark Results

| Model | Mean Latency | P50 (Median) | P95 Latency | Avg FPS | Detection Rate |
| :--- | :--- | :--- | :--- | :--- | :--- |
| ML Kit Fast | 47.61 ms | 45.00 ms | 86.00 ms | 11.38 | 99.71% |
| ML Kit Accurate | 52.50 ms | 50.00 ms | 78.40 ms | 10.22 | 100.00% |
| **MoveNet Lightning** | **14.13 ms** | **14.00 ms** | **16.00 ms** | **24.79** | **100.00%** |
| MoveNet Thunder | 36.98 ms | 37.00 ms | 40.00 ms | 21.45 | 100.00% |
| MediaPipe Pose Lite | 48.47 ms | 49.00 ms | 65.00 ms | 15.93 | 100.00% |

Key observations from the Kotlin benchmark were:

- **MoveNet Lightning** achieved the best raw latency and FPS.
- Several models, including **ML Kit Accurate**, **MoveNet Lightning**, **MoveNet Thunder**, and **MediaPipe Pose Lite**, reached 100% detection coverage in that benchmark setup.
- In practice, the Kotlin-side notes suggest that **MediaPipe Pose Lite** appeared visually more stable for full-body tracking, even when some alternatives were numerically faster.

These two benchmark tracks did not produce exactly the same “best” result, which is reasonable because they were built in different implementation environments. For the **current implemented Flutter application**, the Flutter benchmark is the more relevant decision signal. Therefore, the current prototype uses **ML Kit Pose** as the practical default backend, while the broader benchmarking work still documents potentially useful alternatives for future refinement.

### Presentation Layer

The presentation layer contains the Flutter application entry point and the visible screens:

- `FiTrackApp` initializes the application.
- `HomeScreen` lets the user select an exercise.
- `WorkoutScreen` manages the live session.
- `SummaryScreen` shows the session outcome and quality-related feedback.

In the current implemented architecture, `WorkoutScreen` plays a larger orchestration role than originally envisioned in the proposal. In other words, some coordination logic that might later move into a dedicated controller or ViewModel is still managed directly inside this screen. This is to be cleaned up and structurized better in the future but as we are still prototyping it is not a big problem.

### Service Layer

The service layer abstracts hardware and platform-dependent functionality:

- `CameraService` wraps camera initialization and streaming.
- `PoseService` defines the abstract pose estimation interface.
- `MlKitPoseService` is the current concrete pose estimation backend.
- `TtsService` handles voice feedback.

This structure already provides a useful separation between UI code and low-level camera / inference operations. It also keeps the pose backend replaceable in principle, even though the current prototype is centered on ML Kit.

### Exercise Logic Layer

The exercise logic layer performs the main interpretation of pose data:

- `RepCounter` implements the finite-state-machine logic for curl, squat, and push-up.
- `CurlFormAnalyzer` evaluates curl-specific form errors and quality signals.
- `SquatFormAnalyzer` evaluates squat-specific cues.
- `PushUpFormAnalyzer` evaluates push-up-specific cues.
- `CurlViewDetector` detects whether the user is in front view or side view during curls.
- `LandmarkSmoother`, `OneEuroFilter`, and `AngleUtils` support filtering and geometric calculations.

This is currently the strongest technical part of the system. The repository already includes:

- setup visibility checks before starting a session,
- a hands-free countdown,
- repetition counting with exercise-specific FSM transitions,
- conservative form feedback rules,
- TTS-based cues,
- a summary screen for completed sessions.

The curl pipeline is currently the most mature because it includes view detection, rep quality scoring, fatigue-related logic, and asymmetry checks. Squat and push-up are already supported, but their quality analysis is still intentionally simpler.

### Data / Model Layer

The model layer includes `PoseResult`, `PoseLandmark`, `RepSnapshot`, and shared enums/constants such as `ExerciseType`, `RepState`, and `FormError`.

One important limitation is that **persistent workout storage is not yet implemented in the current Flutter app**, even though it was part of the broader project plan. At the moment, session data is processed in memory and passed to the summary screen, but there is no completed local database/history module yet.

## 3. Class Diagram

This diagram reflects the **current implemented architecture**, not only the intended final design. That distinction is important because the project is still in progress and some responsibilities are currently centralized for faster iteration.

![Class Diagram](class_diagram.png)

## 4. Development Tools and Technologies

The current project stack is:

- **Programming language:** Dart
- **Application framework:** Flutter
- **Pose estimation library:** Google ML Kit Pose Detection
- **Camera integration:** Flutter `camera` package
- **Voice feedback:** `flutter_tts`
- **Version control:** Git
- **Collaboration platform:** GitHub (Issues, branching, pull requests are actively used for collaborative work management)
- **Benchmarking / experimentation:** Separate Flutter and native Android benchmark prototypes in the repository

## 5. Timeline and Planned Work Items

Below is a timeline based on the original proposal, updated to reflect the current repository state.

### Weeks 3-4: Research, Benchmarking, and Model Selection

Status: **Completed**

- Compared candidate pose-estimation approaches.
- Built benchmark prototypes.
- Collected benchmark results for ML Kit, MoveNet, YOLO-based pose, and MediaPipe variants.
- Selected ML Kit as the current working backend because it offered the best speed / integration balance for the prototype.

### Weeks 4-6: Mobile App Foundation

Status: **Largely completed**

- Built the initial Flutter mobile app.
- Added camera preview and skeleton overlay.
- Added exercise selection.
- Added setup visibility checks before session start.
- Added a countdown-based hands-free session start.

### Weeks 6-9: Rep Counting for Core Exercises

Status: **Implemented at prototype level**

- Implemented FSM-based repetition counting.
- Extended support from curl to squat and push-up.
- Added smoothing and geometric feature computation.
- Added confidence gating and occlusion-related handling.

### Weeks 8-11: Form Feedback and Coaching Cues

Status: **Partially completed / in progress**

- Implemented curl form feedback rules such as torso swing, elbow drift, and short range of motion.
- Added initial squat and push-up feedback rules.
- Integrated TTS-based cues and session feedback.
- Added a more detailed curl summary view.

This part is functional, but it still needs further threshold tuning and more systematic evaluation on recorded exercise trials.

### Weeks 9-13: Integration, Logging, and Refinement

Status: **Partially completed**

- Integrated the exercise selection, live session, and summary flow.
- Improved the summary interface for biceps curl.
- Continued refining curl-specific analysis with view detection and quality scoring.

The main incomplete item in this phase is **persistent logging / history storage**. This remains planned work rather than a completed feature.

### Weeks 11-14: Evaluation, Tuning, and Final Demo Preparation

Status: **Current and upcoming work**

Planned remaining items include:

- collecting more structured exercise data,
- tuning thresholds with recorded trials,
- running more systematic evaluation for rep-counting accuracy and feedback behavior,
- cleaning up parts of the architecture as needed,
- finalizing the demo flow and presentation material.

## 6. Current Status and Limitations

We think our project is in a good mid-semester state because the main technical risk has already been addressed: the repository contains a working real-time mobile prototype with pose inference, repetition counting, and feedback logic. This shows that the core idea is feasible on-device.

However, several parts are still **in progress**:

- the current implemented architecture is functional but still somewhat prototype-oriented,
- curl analysis is more mature than squat and push-up analysis,
- persistent workout history is not yet implemented but planned to be added,
- systematic dataset-driven threshold tuning is still ongoing,
- broader evaluation remains part of the remaining work.

