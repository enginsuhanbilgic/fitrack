# Koç University -- COMP 491 Computer Engineering Design
## Project Proposal

# FiTrack
### Spring 2026

**Participant Information:**

| Name | ID | Email | Phone |
| :--- | :--- | :--- | :--- |
| Abdulkadir Bilge | 76471 | abilge20@ku.edu.tr | 0545 956 9274 |
| Abdullah Tunçer | 75640 | atuncer20@ku.edu.tr | 0546 597 6590 |
| Ali Han Kılınç | 75841 | akilinc20@ku.edu.tr | 0553 134 3927 |
| Engin Sühan Bilgiç | 75771 | ebilgic20@ku.edu.tr | 0551 980 5446 |
| Onuralp Keskin | 72725 | onuralpkeskin19@ku.edu.tr | 0532 139 9659 |

**Project Advisor:** Hakan Ayral

---

### Abstract
Many people train alone at home or in the gym without a coach. While online videos demonstrate correct technique, they cannot correct the user while the movement is being performed. As a result, users may repeatedly train with poor form, reducing training efficiency and sometimes increasing the risk of pain or injury. we think a smartphone assistant could provide a low-cost alternative for basic guidance.

FiTrack is a mobile application that uses real-time, camera based pose detection to (1) visualize a skeleton overlay, (2) count repetitions and track sets, (3) provide basic, actionable form feedback, (4) keep a workout log with sets, reps, and weight, and (5) deliver hands-free guidance via a voice assistant. For the foundation, our goal is to build a system that supports three base exercises: *biceps curl, squat, and push-up*. Throughout the proposal, we will use biceps curl as the example because it is relatively constrained and easier to validate, but the pipeline is intended to generalize to the other two base exercises.

We plan to prioritize inference on the device for low latency and privacy. We will benchmark mobile ready pose estimation solutions such as MoveNet (TensorFlow Lite), MediaPipe Pose, and ML Kit Pose Detection, and then decide which model provides the best balance of speed, landmark stability, and integration effort. The expected outcome is a working Android prototype that runs in real time under specified camera placement conditions, provides measurable performance (FPS/latency) and accuracy metrics (rep counting and feedback triggers), and offers a foundation for future extensions such as reference based scoring.

---

## Table of Contents
1. [Introduction](#1-introduction)
2. [S/T Methodology and Associated Work Plan](#2-st-methodology-and-associated-work-plan)
3. [Economical and Ethical Issues](#3-economical-and-ethical-issues)
4. [References](#4-references)

---

# 1. Introduction

## 1.1 Concept
FiTrack is a mobile fitness assistant that provides real-time coaching signals using only a smartphone camera. The target users are individuals who train alone and want immediate feedback without buying extra hardware. The app tracks body landmarks from a live camera feed and draws a skeleton overlay. From these landmarks, FiTrack computes time-series features such as joint angles and normalized distances, then uses them for repetition counting and form feedback.

A key motivation is usability during workouts: users are usually a few meters away from the phone. For this reason, we plan to add hands-free interaction to start and run sessions. We will explore a simple *visual/audio trigger* to start an exercise session, such as an audible countdown with on-screen confirmation, and (if feasible) a lightweight automatic start mechanism based on detecting motion patterns. We will decide the exact interaction after early prototyping.

The project is prioritized on Android first. We would like to consider iOS in future iterations, but we do not currently have a Mac device, so iOS development is not planned as a core deliverable. Still, we will try to keep the design modular so that the same pipeline could be adapted later.

## 1.2 Objectives
By the end of Spring 2026 (Week 14), we aim to deliver an Android prototype that provides real-time pose tracking, rep/set tracking, basic form feedback, voice guidance, and workout logging under clearly defined usage conditions.

- **O1: Real-time pose tracking and visualization.** Run at interactive speed on a mid-range Android device (target: ≥ 15 FPS with overlay), with a nominal per-frame processing budget of approximately 66 ms and end-to-end feedback latency not exceeding 200 ms under recommended camera setup.
- **O2: Rep counting and set tracking for three base exercises.** Support rep counting for *biceps curl, squat, and push-up*. We target ≥ 90% session level rep counting accuracy for biceps curl and aim for comparable performance for squat/push-up under recommended camera placement (exact thresholds may be refined after data collection).
- **O3: Basic form feedback.** Provide conservative, interpretable feedback cues. For the biceps curl MVP, we will implement three core mistake types: torso swing, elbow drift, and short range of motion (ROM). For squat and push-up, we aim to implement at least a small initial set of cues (e.g., depth/hip angle cues for squat and hip sag/ROM cues for push-up).
- **O4: Hands-free interaction and voice guidance.** Provide rep announcements and short corrective cues, plus a hands-free start mechanism (e.g., countdown + audio; optional motion based auto start). Use a cooldown policy to avoid spamming.
- **O5: Workout logging and history.** Persist workout data locally (exercise, sets, reps, weight, timestamp) and display history across app restarts.
- **O6: Documentation and evaluation.** Produce a report with runtime measurements (FPS/latency) and accuracy metrics (rep counting and feedback trigger behavior), and clearly document limitations (camera placement, occlusion, lighting).

## 1.3 Background
Camera-based human pose estimation has matured to the point where it can run on mobile devices with acceptable latency. MoveNet provides a fast 17-keypoint model with Lightning and Thunder variants intended for different latency/accuracy trade-offs [1]. ML Kit Pose Detection provides 33 full-body landmarks with a base vs. accurate option, and documentation emphasizes that full body visibility and sufficient resolution are important for stable results [2]. MediaPipe Pose provides both normalized image landmarks and (in some versions) world landmarks in meters, which may be useful for certain viewpoint robust measurements [3].

Many fitness assistant pipelines build on pose estimation by computing joint angles and normalized geometric features, then applying rule-based logic or similarity scoring to detect reps and form errors. A practical challenge is that 2D projections vary with camera viewpoint, occlusions, lighting, and clothing. For our senior design project which is one semester, we think it is more realistic to define recommended camera placements per exercise and evaluate within those constraints rather than claiming full viewpoint invariance. Real-world gym datasets (e.g., M3GYM) highlight how complex gym settings can be, including occlusions and varying lighting [7].

For movement comparison and scoring, Dynamic Time Warping (DTW) is a common approach to align sequences performed at different speeds. DTW-based scoring has been used to compare user motion against a coach/reference sequence and convert distances into meaningful performance scores [6]. In addition, Pose Trainer proposes a pose estimation based posture correction framework for exercise coaching [5]. We plan to treat reference based scoring as an optional extension; the primary deliverable remains a reliable on-device pipeline for rep counting and conservative feedback.

> **Figure 1 placeholder:** ML Kit's 33 pose landmarks (screenshot from ML Kit docs [2]).
> Add an image file at `figures/mlkit_landmarks.png`.
> *Caption: Pose landmarks visualization example [2]*

## 1.4 Minimum Viable Product (MVP) Definition
To ensure project success within the 12-week timeline, we define our MVP as a fully functional **Biceps Curl Assistant**. While the pipeline is designed to eventually support multiple exercises, the MVP phase prioritizes robust feedback and rep-counting specifically for the Biceps Curl.

To be considered “Done,” the MVP must successfully handle the following:
- **Real-time Pose Tracking:** Stable keypoint detection at ≥ 15 FPS.
- **Rep Counting logic:** A logic-based state machine (IDLE → CONCENTRIC → PEAK → ECCENTRIC → IDLE) to track sets and reps accurately.
- **Form Feedback (The MVP Rulebook):**
    1. **Torso Swing Detection:** Measuring shoulder-to-hip horizontal displacement to detect momentum abuse.
    2. **Elbow Stability Check:** Monitoring elbow landmark drift to ensure the shoulder isn't taking over the movement.
    3. **ROM (Range of Motion) Check:** Identifying “half-reps” by monitoring joint angle thresholds.
- **Primary Feedback Loop:** Visual skeleton overlay and voice-guided corrective cues.

Post-MVP goals include Squat and Push-up integration, and advanced history visualization. By strictly defining the MVP, we ensure the core architecture is rigorously tested and mathematically measurable.

# 2. S/T Methodology and Associated Work Plan

## 2.1 Methodology
FiTrack follows a modular pipeline from camera input to coaching output. We aim to keep the core loop lightweight enough for on-device real-time processing.

#### Pose inference (on-device).
We will prototype three candidate solutions and decide based on early benchmarking:
- MoveNet (TensorFlow Lite) [1]
- ML Kit Pose Detection on Android [2]
- MediaPipe Pose [3]
We will decide the final model after our experiments on frame rate, latency and landmark stability.

#### System Architecture.
Figure 2 organizes FiTrack into four main processing layers plus local persistence. **CameraX API** captures the live YUV frame stream from the phone camera. The **Inference Pipeline**, which runs on a background thread, performs pose estimation, jitter reduction using the 1€ Filter, and feature extraction. The **Domain Logic** layer contains the rep state machine, form rulebook, and feedback coordinator responsible for cooldown and priority management. The **Presentation Layer** contains the Android UI, TTS engine, and Workout ViewModel, which render feedback and manage session state on the main thread. Workout data is stored locally through **Room Database**.

> **Figure 2 placeholder:** FiTrack high-level architecture.
> *Caption: FiTrack high-level architecture. CameraX API provides the YUV frame stream; the Inference Pipeline performs pose estimation, smoothing, and feature extraction on a background thread; Domain Logic evaluates repetition state and form rules; and the Presentation Layer renders UI/TTS feedback and manages session state on the main thread. Workout data is stored locally through Room Database.*

#### The Pipeline Breakdown (Life of a Frame).
To maintain interactive operation at ≥ 15 FPS, the system targets a nominal per-frame processing budget of approximately ~66 ms. This frame-level budget is distinct from the overall end-to-end latency target of at most 200 ms from frame capture to visible or audio feedback. The processing flow follows the same four-layer structure shown in Figure 2:
1. **CameraX API (< 10 ms target):** CameraX captures the YUV image frame and forwards it to the analysis pipeline.
2. **Inference Pipeline (< 35 ms target):** The pose estimator predicts body landmarks with confidence scores, the 1€ Filter smooths landmark trajectories, and feature extraction computes quantities such as θ_elbow and normalized distances like ΔX_shoulder / L_torso. As an initial confidence gate, frames in which the required landmarks for the active exercise fall below c = 0.4 are ignored for rep counting and corrective feedback.
3. **Domain Logic (< 10 ms target):** The rep state machine updates the current exercise phase, the form rulebook evaluates torso swing, elbow drift, and ROM conditions, and the feedback coordinator applies cooldown and priority rules before issuing feedback events.
4. **Presentation Layer (< 10 ms target):** The Android UI renders the skeleton overlay and counters, the TTS engine delivers rep announcements or corrective cues, and the Workout ViewModel updates session state and persists logs through Room Database when needed.

> **Figure 3 placeholder:** Layered FiTrack processing flow from camera input to user feedback.
> *Caption: Layered FiTrack processing flow from camera input to user feedback. CameraX API supplies the YUV frame stream; the Inference Pipeline performs pose estimation, smoothing, and feature extraction; Domain Logic evaluates rep state and form rules; and the Presentation Layer renders UI/TTS feedback and manages session state. The system targets interactive performance at ≥ 15 FPS (nominal ~66 ms per processed frame) and end-to-end feedback latency of at most 200 ms.*

#### Biomechanical Models and Landmark Tracking.
For clarity, the MVP description assumes a 33-landmark schema such as ML Kit / MediaPipe, where shoulders, elbows, wrists, and hips correspond to landmarks 11–16 and 23–24. If MoveNet is selected, the same logic will be implemented using the corresponding 17-keypoint mapping.

> **Figure 4 placeholder:** MVP Biomechanical Model for Biceps Curls.
> *Caption: MVP Biomechanical Model for Biceps Curls. The elbow angle θ drives the rep state machine, while horizontal deviation ΔX identifies form errors.*

The mathematical models driving the MVP include:
- **Rep Counting (Elbow Angle θ):** Calculated using the dot product of vectors from the elbow to the shoulder (BA) and wrist (BC).
- **Torso Swing (Momentum Error):** We detect back swinging by measuring the horizontal displacement of the shoulder (ΔX_shoulder), normalized by the torso length (L_torso = |y_23 - y_11|). If Swing_score > 0.15, a "Don't swing" alert is triggered.
- **Elbow Drift (Isolation Error):** We measure forward/backward elbow movement (ΔX_elbow) normalized by L_torso. If Drift_score > 0.10, a “Keep your elbow still” alert is triggered.

#### Finite State Machine (FSM) Logic.
To prevent false-positive rep counts caused by minor camera jitter (e.g., hovering around a threshold), the logic engine employs an FSM with hysteresis thresholds.

> **Figure 5 placeholder:** Biceps Curl UML State Machine.
> *Caption: Biceps Curl UML State Machine. Hysteresis thresholds (150°, 40°, 50°, 160°) prevent noise-induced false rep counts. Form evaluation triggers user feedback exclusively during CONCENTRIC and ECCENTRIC states.*

The state transitions are defined as follows:
1. **IDLE → CONCENTRIC:** Triggered when θ < 150°. Form Rulebook activates to check for swinging.
2. **CONCENTRIC → PEAK:** Triggered when θ ≤ 40°.
3. **PEAK → ECCENTRIC:** Triggered when θ > 50° (a 10° hysteresis gap prevents bouncing false alarms). Form Rulebook activates to check for elbow drift.
4. **ECCENTRIC → IDLE:** Triggered when θ ≥ 160°. Rep complete; `count++`.

#### The Hands-Free Journey and End-to-End Feedback.
Because the user operates the system from a distance, interactions are driven mostly by state changes and TTS audio. The session journey is structured into four phases:
1. **Setup:** The user selects the exercise and steps back.
2. **Validation:** The system ensures that the required body parts for the selected exercise are visible and initiates an audio countdown.
3. **Execution:** The core loop tracks reps ("One... Two...") and injects corrective cues only when rulebook thresholds are breached.
4. **Termination:** Detecting absence of the user, the app auto-saves the log and exits.

> **Figure 6 placeholder:** FiTrack User Journey Map.
> *Caption: FiTrack User Journey Map detailing Setup, Validation, Execution, and Termination phases. The system uses confidence thresholds (c > 0.4) to auto-start, monitors biomechanics (ΔX_shoulder > 15%) for real-time audio feedback, and auto-terminates and saves when the user exits the frame.*

#### Workout logging.
We will store workout entries locally (exercise, sets, reps, weight, timestamps) and show a basic history view. We prefer on-device storage for offline use and privacy for now.

#### Optional extension: reference-based scoring.
If time permits, we will explore comparing user movement sequences against reference recordings (e.g., trainer recordings). DTW can align sequences performed at different speeds [6]. Pose Trainer provides inspiration for posture correction approaches [5]. This part is explicitly a stretch goal.

#### Main on-device pipeline (MVP).
CameraX API → Inference Pipeline → Domain Logic → Presentation Layer → Room Database

## 2.2 Work Package Descriptions
The project work spans weeks 3-14 (12 weeks). As the first two weeks were gathering the group and deciding on the project, we start the timeline with third week.

### Work Package 1: Early research, benchmarking, and data plan (Weeks 3–4)
**Participants:** Engin (lead), Abdulkadir (lead); support: Abdullah, Ali Han, Onuralp
**Objectives:** Identify candidate pose models; define the three base exercises and camera placement guidelines; design evaluation protocol; start data collection early.
**Tasks:**
- **T1.1 (w3)** Read and summarize key references on mobile pose estimation and coaching pipelines [1, 2, 3, 5].
- **T1.2 (w3–w4)** Quick benchmark prototypes for candidate pose solutions (FPS/latency/jitter notes).
- **T1.3 (w4)** Define base exercises (curl/squat/push-up), recommended camera placements, and hands-free start approach (initial design).
- **T1.4 (w4)** Data plan: define what videos to record (good form + common mistakes) and how to label them.
**Deliverables:** D1.1 model comparison notes; D1.2 initial evaluation protocol; D1.3 data collection checklist.
**Milestone:** M1.1 selected primary pose approach (or top-2 shortlist) and initial dataset plan.

### Work Package 2: Mobile app foundation + early data collection (Weeks 4–6)
**Participants:** Abdullah (lead), Ali Han (lead), Onuralp; support: Engin, Abdulkadir
**Objectives:** Build the Android camera pipeline and overlay; implement exercise selection; implement hands-free start baseline; collect reference videos early.
**Tasks:**
- **T2.1 (w4–w5)** Implement camera capture and frame preprocessing, skeleton overlay visualization.
- **T2.2 (w5–w6)** Add exercise selection UI and setup checks (framing/visibility).
- **T2.3 (w5–w6)** Add hands-free start baseline (countdown with audio + large UI).
- **T2.4 (w4–w6)** Record initial reference data (team members and, if possible, one trainer/experienced lifter) for the three base exercises.
**Deliverables:** D2.1 runnable Android demo (camera + overlay); D2.2 initial recorded dataset.
**Milestone:** M2.1 stable end-to-end pose tracking demo on target phone.

### Work Package 3: Feature extraction + rep counting for three exercises (Weeks 6–9)
**Participants:** Abdulkadir (lead), Engin (lead), Onuralp; support: Abdullah/Ali Han(integration)
**Objectives:** Implement smoothing and core feature library; implement rep counting for curl/squat/push-up.
**Tasks:**
- **T3.1 (w6–w7)** Implement smoothing (1€ filter) and joint-angle computations [4].
- **T3.2 (w7–w8)** Implement rep counting state machines (curl as example; adapt to squat/push-up).
- **T3.3 (w8–w9)** Threshold tuning using early dataset; add confidence gating and “setup adjustment” prompts.
**Deliverables:** D3.1 rep counting modules for three exercises; D3.2 short internal test report.
**Milestone:** M3.1 rep counting works reliably on initial tests under recommended setup.

### Work Package 4: Form feedback + voice guidance (Weeks 8–11)
**Participants:** Abdullah (lead), Onuralp (lead), Engin; support: Abdulkadir/Ali Han
**Objectives:** Implement rule-based form feedback; integrate voice feedback; keep cues conservative and testable.
**Tasks:**
- **T4.1 (w8–w9)** Define the MVP rulebook for biceps curl (torso swing, elbow drift, and partial ROM), and a smaller initial cue set for squat/push-up (at least 1–2 cues each).
- **T4.2 (w9–w10)** Implement feedback visualization and voice prompts; implement cooldown policy.
- **T4.3 (w10–w11)** Tune feedback triggers using early dataset and record additional clips if needed.
**Deliverables:** D4.1 rulebook document + implemented feedback; D4.2 voice enabled workout flow.
**Milestone:** M4.1 feedback triggers are meaningfully different between good vs. bad trials in controlled tests.

### Work Package 5: Logging, integration, and optional reference scoring (Weeks 9–13)
**Participants:** Abdullah (lead), Ali Han, Onuralp; support: Engin, Abdulkadir
**Objectives:** Add workout logging/history; integrate modules; optionally prototype reference scoring if time allows.
**Tasks:**
- **T5.1 (w9–w11)** Implement local log and history UI (exercise, sets, reps, weight, timestamp).
- **T5.2 (w11–w12)** Integrate logging with events from rep counting and feedback.
- **T5.3 (w12–w13, optional)** Prototype DTW-based reference scoring using recorded reference clips [6, 5].
**Deliverables:** D5.1 logging + history screens; D5.2 integrated app build; (optional) D5.3 reference scoring prototype notes.
**Milestone:** M5.1 End to end, feature complete MVP flow.

### Work Package 6: Evaluation, refinement, and final demonstration (Weeks 11–14)
**Participants:** All (Engin leads reporting/documentation)
**Objectives:** Structured evaluation; refinement; final demo and final report.
**Tasks:**
- **T6.1 (w11–w13)** Collect evaluation trials (good/bad form) for three exercises under recommended setups.
- **T6.2 (w12–w13)** Compute metrics (FPS/latency, rep accuracy, feedback trigger behavior).
- **T6.3 (w12–w14)** Polish UI/UX; finalize report; rehearse demo.
**Deliverables:** D6.1 evaluation report + limitations; D6.2 final APK + demo script/slides.
**Milestone:** M6.1 final demonstration and submission.

## 2.3 System Evaluation and Numeric Success Criteria
To ensure FiTrack meets the requirements of a reliable mobile fitness assistant, we established a quantitative evaluation framework.

The final demonstration will present this end-to-end Android prototype running in real time, intentionally including a controlled “mistake demo” where a user performs common errors to visibly and audibly trigger the system's rulebook.

#### 1. Algorithmic Performance Metrics.
Our primary accuracy metric is the **Mean Absolute Error (MAE)**, which measures the difference between the system's predicted rep count (ŷ) and the manual ground truth (y) across n test sessions:
MAE = (1/n) * Σ |y_i - ŷ_i|
To account for variable range-of-motion during fatigue, we set a strict target of **MAE ≤ 1.5**.

To guarantee user trust, the system must minimize false-positive alerts. We evaluate the reliability of corrective cues using **Precision**:
Precision = TP / (TP + FP)
Where TP (True Positive) is a correctly identified form error and FP (False Positive) is a false alarm during a correct rep. We target a **Precision ≥ 75%**.

#### 2. System Performance & Numeric Thresholds.
To directly address latency, false alarms, and architectural constraints, the following numeric thresholds dictate system success (see Table 1):

| Metric | Success Threshold | Engineering Rationale |
| :--- | :--- | :--- |
| **Inference Speed** | ≥ 15 FPS | Minimum required for interactive, real-time feedback. |
| **System Latency** | ≤ 200 ms | Prevents delayed or disjointed audio prompts. |
| **MAE (Rep Count)** | ≤ 1.5 Reps | Forgiving for partial-ROM reps during fatigue. |
| **Feedback Precision** | ≥ 75% | Ensures coach reliability and user trust. |
| **False Alarm Rate** | ≤ 25% of good-form reps | Fraction of corrective cues triggered during manually labeled good-form repetitions. |
| **Confidence Gating** | c > 0.4 | Guarantees robustness in sub-optimal lighting. |
| **Audio Cooldown** | 3.0 Seconds | Prevents spamming repetitive cues. |

#### 3. Heuristic Rulebook Thresholds (MVP).
The following mathematical thresholds will be used to trigger the MVP feedback loops, utilizing normalized distances based on torso length (L_torso) for scale invariance:
- **Torso Swing Threshold:** ΔX_shoulder / L_torso > 0.15
- **Elbow Drift Threshold:** ΔX_elbow / L_torso > 0.10
- **Rep Start/End Guard:** θ_elbow > 150°
- **Rep Peak Guard:** θ_elbow ≤ 40°

## 2.4 Impact
We think FiTrack can make basic exercise coaching more accessible by turning a smartphone into a real-time gym assistant for people who train alone. Even simple rep counting, conservative form cues, and hands-free voice guidance may help users notice repeated mistakes, stay consistent, and track progress without requiring expensive equipment. In the longer term, the same approach could be extended to more exercises and improved robustness, but in this course project we will focus on building a reliable foundation and clearly documenting limitations.

## 2.5 Risk Analysis

| Risk | Likelihood | Impact | Mitigation |
| :--- | :--- | :--- | :--- |
| Pose tracking degrades (lighting, occlusion, clothing, camera angle). | M | H | Recommend camera placement per exercise; setup checks; confidence gating; smoothing; evaluate only under documented conditions. |
| Real-time performance too slow on some Android devices. | M | H | Choose mobile optimized model/variant; reduce input resolution; optimize overlay rendering; benchmark early (WP1–2). |
| Form feedback produces false/unsafe cues. | M | H | Use conservative, interpretable rules; apply confidence gating (c > 0.4); enforce a 3 s audio cooldown; tune thresholds on early data; and clearly communicate limitations. |
| Hands-free start is unreliable. | M | M | Keep a robust baseline (countdown + audio) even if auto start is removed; decide after early tests. |
| Scope creep (too many exercises/features). | M | M | Lock base exercises to 3; treat DTW/reference scoring and hybrid uploads as stretch goals. |
| Privacy concerns. | L | H | On-device processing by default; do not store raw video; keep only workout logs; any keypoint logging is optional. |

## 2.6 Gantt Chart
Planned schedule over 14 weeks. Weeks 1–2 are reserved for group formation and topic finalization; project work starts at Week 3.

| WP | W1 | W2 | W3 | W4 | W5 | W6 | W7 | W8 | W9 | W10 | W11 | W12 | W13 | W14 |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| WP1 | | | X | X | | | | | | | | | | |
| WP2 | | | | X | X | X | | | | | | | | |
| WP3 | | | | | | X | X | X | X | | | | | |
| WP4 | | | | | | | | X | X | X | X | | | |
| WP5 | | | | | | | | | X | X | X | X | X | |
| WP6 | | | | | | | | | | | X | X | X | X |

# 3. Economical and Ethical Issues

## 3.1 Economical Issues
FiTrack is designed to run primarily on-device, which we think reduces operational costs because it does not require continuous server side video processing. The main costs are development time and testing on phones already owned by the team. If we explore an optional hybrid extension later, we would prefer uploading only compact pose keypoint time series or derived angles instead of raw video, which would reduce bandwidth and storage compared to full video upload. However, server usage would still add recurring costs and extra engineering overhead, so it is not required for the MVP.

## 3.2 Ethical Issues
FiTrack operates in a domain where incorrect guidance could cause harm if it is overstated or misleading. We will avoid medical claims and clearly present feedback as informational rather than professional coaching or medical advice. We will also aim to be transparent about limitations (camera placement, occlusion, lighting) and handle low confidence situations carefully.

Privacy is also a major concern because the system uses a camera feed. For the MVP, we aim to process video on the device and will not store or transmit raw video by default. Only workout logs (sets, reps, weights, timestamps) will be stored locally. If we store any pose keypoints for testing purposes, we plan to make this optional and avoid collecting identifiable video frames.

# 4. References

1. TensorFlow Hub, “MoveNet: Ultra fast and accurate pose detection model,” [https://www.tensorflow.org/hub/tutorials/movenet](https://www.tensorflow.org/hub/tutorials/movenet), accessed 2026-02-28.
2. Google Developers, “Detect poses with ML Kit on Android,” [https://developers.google.com/ml-kit/vision/pose-detection/android](https://developers.google.com/ml-kit/vision/pose-detection/android), accessed 2026-02-28.
3. MediaPipe Documentation, “Pose solution / pose_world_landmarks output,” [https://mediapipe.readthedocs.io/en/latest/solutions/pose.html](https://mediapipe.readthedocs.io/en/latest/solutions/pose.html), accessed 2026-02-28.
4. G. Casiez, N. Roussel, and D. Vogel, “1€ Filter: A Simple Speed-based Low-pass Filter for Noisy Input in Interactive Systems,” *CHI 2012*. Resource page: [https://gery.casiez.net/1euro/](https://gery.casiez.net/1euro/), accessed 2026-02-28.
5. S. Chen and R. Yang, “Pose Trainer: Correcting Exercise Posture using Pose Estimation,” arXiv:2006.11718, 2020. [https://arxiv.org/abs/2006.11718](https://arxiv.org/abs/2006.11718), accessed 2026-02-28.
6. X. Yu and S. Xiong, “A Dynamic Time Warping Based Algorithm to Evaluate Kinect-Enabled Home-Based Physical Rehabilitation Exercises for Older People,” *Sensors*, 19(13), 2882, 2019. [https://www.mdpi.com/1424-8220/19/13/2882](https://www.mdpi.com/1424-8220/19/13/2882).
7. Q. Xu et al., “M3GYM: A Large-Scale Multimodal Multi-view Multi-person Pose Dataset for Fitness Activity Understanding in Real-world Settings,” *CVPR 2025*. Open access: [https://openaccess.thecvf.com/content/CVPR2025/html/Xu_M3GYM_A_Large-Scale_Multimodal_Multi-view_Multi-person_Pose_Dataset_for_Fitness_CVPR_2025_paper.html](https://openaccess.thecvf.com/content/CVPR2025/html/Xu_M3GYM_A_Large-Scale_Multimodal_Multi-view_Multi-person_Pose_Dataset_for_Fitness_CVPR_2025_paper.html), accessed 2026-02-28.
