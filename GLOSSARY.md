# FiTrack Glossary — Project Vocabulary

> **This file is the single source of truth for every FiTrack-specific term.**
> Code, commits, PRs, issues, brain files, chat transcripts, and user-facing
> text must use these exact terms. If you need a new term, add it here first,
> then use it elsewhere.
>
> **Last updated:** 2026-04-25 · **Maintainer duty:** any contributor who
> coins a term is responsible for updating this file in the same PR.

---

## 0. How to use this glossary

- **Ambiguity check** — when two contributors mean different things, open
  this file. The definition here wins; update usages in the offending PR.
- **Casing and spelling** — use the exact casing shown (e.g. `RepCounter`,
  not `rep counter` or `Rep_Counter`, when referring to the class; but
  "rep counter" lowercase when talking about the *concept* in prose).
- **Don't coin silently** — a new term in a PR without a glossary entry
  is a review comment.
- **Retire carefully** — if a term becomes obsolete, mark it as
  **deprecated** here with the replacement name; don't just delete it.
  Old commits and docs still reference it.

Entries are grouped by category, not alphabet, because contributors
usually know *what kind* of term they're looking up before they know its
exact name.

---

## 1. Core Calibration Vocabulary (the lock)

These two systems must never be conflated. The brain's `SKILLS.md §8b`
holds the canonical rule; this table is its projection.

| Term | What it is | Where it lives | When it runs |
|---|---|---|---|
| **Default ROM Threshold** | The offline dataset-driven derivation of the FSM's **starting** thresholds. Developer-run, produces the defaults every user gets on first launch. | `tools/dataset_analysis/` (Python + Dart replay harness) | Offline, at dev time, before shipping new defaults |
| **Personal Calibration** | On-device per-user adaptation of the FSM thresholds to the individual's anatomy. User-visible. | `app/lib/engine/curl/curl_rom_profile.dart`, `curl_auto_calibrator.dart`, `rep_boundary_detector.dart`, `screens/calibration_overlay.dart` | First biceps-curl workout (or Settings → Recalibrate); auto-calibrator continues in every set |
| **Auto-Calibration** | The **in-set** sub-feature of Personal Calibration. Builds transient thresholds after ≥ 2 reps without requiring a dedicated calibration phase. | `app/lib/engine/curl/curl_auto_calibrator.dart` | Every active set, per-view, after 2 valid reps with ROM ≥ `kMinViableRomDegrees` |

**Speaking rules:**
- Unqualified "calibration" → assume **Personal Calibration** (the only one users see).
- "Default ROM Threshold" → always means the offline tool. Never abbreviate to "calibration".
- "Auto-calibration" → never stands alone; always understood as a part of Personal Calibration.
- ❌ Reject: "calibration pipeline" (ambiguous), "user calibration for defaults" (conflated).

---

## 2. Rep-Counting FSM

### 2.1 State machine

| Term | Meaning |
|---|---|
| **FSM** | Finite State Machine. The engine that counts reps for a given exercise. Lives in `app/lib/engine/rep_counter.dart`. |
| **RepCounter** | The Dart class wrapping the FSM. Exposes `onPose(PoseResult)` and a `snapshot` getter. Single source of truth for rep counting — never ported, only imported (e.g. by the replay harness via `path:` dep). |
| **RepSnapshot** | Immutable public snapshot of FSM state. Fields: `reps`, `state`, `source` (`ThresholdSource`), and any exercise-specific extras. Consumed by UI; do not mutate. |
| **RepState** | Enum of FSM states. Curl uses `idle / concentric / peak / eccentric`; squat + push-up use `idle / descending / bottom / ascending`. |

### 2.2 Curl rep phases (lifecycle)

Rep lifecycle (exact transition names used in code, telemetry, docs):

```
IDLE → CONCENTRIC → PEAK → ECCENTRIC → IDLE (rep++)
```

| Phase | Definition |
|---|---|
| **IDLE** | Arm is at or near full extension. FSM waits for concentric trigger. |
| **CONCENTRIC** | Lifting phase — elbow flexing, weight travelling up. |
| **PEAK** | Top of the curl — elbow at or past `peakAngle`. |
| **ECCENTRIC** | Lowering phase — weight travelling down, elbow extending. |

Squat and push-up use the parallel phase names `descending / bottom / ascending`.

### 2.3 Threshold gates (curl)

| Term | Code constant | Trigger |
|---|---|---|
| **Start angle** | `curlStartAngle` | IDLE → CONCENTRIC (elbow crosses below this) |
| **Peak angle** | `curlPeakAngle` | CONCENTRIC → PEAK (elbow crosses below this) |
| **Peak-exit angle** | `curlPeakExitAngle` | PEAK → ECCENTRIC (elbow crosses above this) |
| **End angle** | `curlEndAngle` | ECCENTRIC → IDLE, increments rep count |
| **Peak-exit gap** | `kCurlPeakExitGap` = 15° | Hysteresis gap: `peakExitAngle = peakAngle + kCurlPeakExitGap` |

**FSM invariant chain** (enforced by both the on-device FSM and the
offline derivation's `check_invariants()`):

```
start > peak_exit   AND   start > end   AND   end > peak_exit   AND   peak < start
```

A threshold set that violates any of these is **un-enterable** — the
FSM can't transition through every state, so no reps are counted.

### 2.4 Supporting guards

| Term | Definition |
|---|---|
| **Debounce** | `kStateDebounce` (500 ms) lockout after every FSM transition. Prevents micro-jitter from double-counting. |
| **Stuck-state timer** | `kStuckStateLimit` (5 s). FSM auto-resets to IDLE if the user freezes in a non-idle state (the "Zombie" user). |
| **Confidence gate** | `kMinLandmarkConfidence` (0.4). Landmarks below this are treated as missing. |
| **Far-side confidence gate** | `kFarSideConfidenceGate` (0.4). In side view, the far arm's landmarks often drop — if C_far < gate, the near-side limb is used as proxy. |
| **Threshold-lock invariant** | Thresholds (and their `ThresholdSource`) are resolved **once per rep, at IDLE→CONCENTRIC**, and pinned for the rest of that rep. Prevents mid-rep source swaps that cause silent rep loss through hysteresis-gap thrashing. |

---

## 3. Personal Calibration & ROM Profile

### 3.1 Core types

| Term | Meaning |
|---|---|
| **ROM** | Range of Motion. The angle span from rest (max angle) to peak flexion (min angle) for a rep. |
| **CurlRomProfile** | Per-user persisted profile for biceps curls. A sparse map of `(side, view) → RomBucket`. One file per user at `getApplicationDocumentsDirectory()/profiles/biceps_curl.json`. |
| **RomBucket** | Observed-ROM data for one `(ProfileSide, CurlCameraView)` combination. Holds `observedMinAngle`, `observedMaxAngle`, `sampleCount`, and metadata. |
| **RomThresholds** | Immutable value object — the four FSM gates (`startAngle`, `peakAngle`, `peakExitAngle`, `endAngle`) plus a `ThresholdSource`. Produced by `RomThresholds.fromBucket()` / `.fromAuto()` / `.global()`. |
| **ThresholdSource** | Enum: `calibrated` / `autoCalibrated` / `warmup` / `global`. Records which mechanism produced the thresholds for a rep. |
| **ProfileSide** | Enum `{ left, right }`. Distinct from `ExerciseSide` because a bucket describes exactly one limb — `both` / `unknown` are never valid bucket keys. |
| **CurlCameraView** | Enum `{ unknown, front, sideLeft, sideRight }`. Auto-detected during `setupCheck`, locked for the session (until view-change logic re-runs). |
| **bicepsCurlFront** | `ExerciseType` variant for front-facing camera. The user selects this at exercise selection time; `CurlStrategy` is constructed with `initialView: CurlCameraView.front`, making the locked view immutable for the session. |
| **bicepsCurlSide** | `ExerciseType` variant for side-facing camera. Elbow angles differ geometrically from front view (~60° vs ~5° at peak in 2D projection). Constructed with `initialView: CurlCameraView.sideLeft/sideRight` based on the working arm. |
| **isCurl** | Convenience getter on `ExerciseType`. Returns `true` for `bicepsCurlFront`, `bicepsCurlSide`, and the deprecated `bicepsCurl`. Used throughout the codebase in place of per-variant equality checks. |
| **CurlProfileBucketSummary** | Read-only snapshot of a bucket for the Summary screen. Decoupled from `RomBucket` so UI doesn't import engine. |

### 3.2 Threshold derivation (on-device, `RomThresholds.fromBucket`)

```
startAngle    = observedMaxAngle - kProfileStartTolerance  (10°)
peakAngle     = observedMinAngle + kProfilePeakTolerance   (15°)
peakExitAngle = peakAngle        + kCurlPeakExitGap        (15°)
endAngle      = observedMaxAngle - kProfileEndTolerance    (25°)
```

Warmup (first `kProfileWarmupReps` = 2 reps of every set): all
tolerances multiplied by `kProfileWarmupMultiplier` = 1.5.

### 3.3 Bucket update mechanics

| Term | Meaning |
|---|---|
| **Asymmetric EMA** | Different smoothing rates for expanding (`kProfileExpandAlpha` = 0.4, immediate) vs shrinking (`kProfileShrinkAlpha` = 0.1, with confirmation). Rationale: anatomy doesn't shrink; fatigue-driven shrinkage must be confirmed across reps. |
| **Shrink-pending** | A rep whose sample is narrower than the current bucket triggers this state. Requires `kProfileShrinkConfirmReps` = 3 consecutive confirming reps before the shrink actually applies. |
| **MAD outlier rejection** | Median + Median Absolute Deviation over the last `kProfileOutlierWindow` = 8 samples. Reject if `|sample − median| > kProfileMadThreshold × MAD` (2.5×). Chosen over mean/stddev for small-window robustness. Implemented as shared top-level functions `isMadOutlier(window, sample)` and `median(sorted)` in [mad_outlier.dart](app/lib/engine/curl/mad_outlier.dart); used by both `RomBucket` (persistent per-(side,view) profile) and `CurlAutoCalibrator` (transient in-set average). Constant-window edge case: MAD of identical samples is 0 → returns `false` (any deviation is technically "infinite MADs" but is biologically valid). |
| **mad_outlier.dart** | [app/lib/engine/curl/mad_outlier.dart](app/lib/engine/curl/mad_outlier.dart) — shared MAD utility. Exposes `isMadOutlier(List<double> window, double sample) → bool` and `median(List<double> sorted) → double`. Callers own the sample window, typically bounded by `kProfileOutlierWindow`. |
| **Warmup reps** | The first `kProfileWarmupReps` reps of every set apply inflated tolerances — the user hasn't found full ROM yet. |
| **Front-view dual-bucket rule** | In `front` view, both arms visible. Update **both** `(left, front)` and `(right, front)` buckets only when both arms reached PEAK with delta < `kAsymmetryAngleDelta`. Otherwise update only the working side. Prevents unilateral curls from training both sides. |
| **View-unknown drop** | If `_lockedView == CurlCameraView.unknown` at rep commit, the sample is dropped entirely (no bucket updated). Logs `rep.commit_skipped_view_unknown`. |

### 3.4 Calibration phase

| Term | Meaning |
|---|---|
| **Calibration phase** | The `WorkoutPhase.calibration` state — a *phase*, not a route. Shares the workout's camera/pose stream (no second `MLKitPoseService`). |
| **CalibrationOverlay** | Stateless widget that renders while in the calibration phase. Shows rep dots, live angle, view chip, timer, skip/retry actions. |
| **RepBoundaryDetector** | Zero-crossing detector with 3-frame turning-point confirmation, min `kCalibrationMinExcursion` (40°) excursion, and `kRepBoundaryMinDwellFrames` (8) moving-frames-in-descending dwell. Replaces the FSM **during calibration only** — we can't use the FSM to build its own thresholds. |
| **Rep-boundary minimum dwell** | Moving-frame count the detector must accumulate in `_Phase.descending` before a descending → ascending flip commits a rep. Constant: `kRepBoundaryMinDwellFrames = 8` (≈ 267 ms @ 30 fps). Frame-based (not wallclock) to keep the synthetic-frame test harness deterministic. Rejects rest-pause noise flip-flops that would otherwise commit phantom reps. Plateau frames (`stepDir == 0`) don't count — they're precisely the failure mode the guard is closing. |
| **Calibration success criteria** | ≥ `kCalibrationMinReps` (3) valid reps within `kCalibrationTimeoutSec` (60 s). Each rep must clear `ROM ≥ kMinViableRomDegrees` (25°) and `framePassRate ≥ kCalibrationFramePassRate` (0.80). |
| **Opt-in only** | Personal calibration is **never auto-launched**. The only entry points are (a) Settings → Recalibrate and (b) the in-workout gear icon → Calibrate now. A fresh `CurlRomProfile` with empty buckets runs on globals (`ThresholdSource.global`) until the user explicitly chooses to calibrate. This is a user-experience invariant, not a threshold-math decision. |
| **Force-calibrate** | The `WorkoutScreen(forceCalibration: true)` entry path — the single code path that enters the calibration phase. Fired by Settings → Recalibrate or the in-workout gear's "Calibrate now" action. |

### 3.5 Auto-Calibration (`CurlAutoCalibrator`)

| Term | Meaning |
|---|---|
| **In-set transient profile** | Per-set, in-memory synthetic bucket built from the first reps of the current set. Returns `null` until ≥ 2 reps observed AND `ROM ≥ kMinViableRomDegrees` (25°). Reset on set boundary or view-lock change. |
| **Per-dimension MAD guard (auto-calibrator)** | Each rep's `min` and `max` are filtered independently through `isMadOutlier` against separate `_minSamples` / `_maxSamples` windows (bounded by `kProfileOutlierWindow` = 8). Rationale: a rep with a new PR peak (legitimate bucket-expanding data) may still pair with a normal rest angle. Rejecting both in lockstep would discard valid samples. Running average of each dimension only advances on accepted samples; `repCount` advances when at least one dimension was accepted. |
| **Threshold resolution chain** | Per-rep decision at IDLE→CONCENTRIC: bucket (`calibrated`) → auto (`autoCalibrated`) → warmup-modified → globals (`global`). First match wins; pinned for the rep. |

---

## 4. Form Analysis

### 4.1 Form errors (`FormError` enum)

| Term | Exercise | Trigger |
|---|---|---|
| **Torso swing** | Biceps curl | Hip/shoulder horizontal drift > `kSwingThreshold` (0.25× torso length). Momentum abuse — lateral (X-axis) cheat. |
| **Depth swing** (`FormError.depthSwing`) | Biceps curl (front view only) | Sagittal rocking toward/away from the camera. Detected by [Sagittal Sway Detector](#41b-sagittal-sway-detector) — a composite of three scale-invariant features (shoulder/hip width ratio `f₁`, torso area / hip width² `f₂`, torso length / shoulder width `f₃`), 1€-filtered, z-scored against a per-session baseline of neutral-pose frames, and classified on time-normalized velocity `v = ΔS/Δt` with N-frame hysteresis. Both forward and backward sway emit the same `FormError.depthSwing`. Two defense layers prevent false positives from arm-over-torso occlusion (the curling arm shadowing the shoulders/hips): the [Arm-Over-Torso Occlusion Gate](#41c-arm-over-torso-occlusion-gate) skips the detector entirely when the curling arm sits inside the torso bounding box, and the [Head Stability Corroborator](#41d-head-stability-corroborator) vetoes the warning when the head shows no corresponding motion. Cue: "Don't rock toward the camera". Highlights both shoulders. Reuses the lateral-swing quality budget (`kQualitySwingMaxDeduction` = 0.25) — the user experiences both as "torso momentum cheat" so they share one deduction cap; the deduction scales with the peak `|composite z|` seen during the rep. |
| **Shoulder arc** (`FormError.shoulderArc`) | Biceps curl (side views only) | Hip-pivot rotation: 2D displacement of the shoulder *in the hip's local frame* (`Δ(shoulder − hip)` from rep-start baseline), normalized by torso length, exceeds `kSwingThreshold` (0.25). Anchoring at the hip cancels whole-body translation, isolating only the rotational component — the "semicircle" the shoulder traces when the lifter pivots their torso forward/back at the hip joint. Complements the existing side-view trunk-lean angle check (different motion: trunk-tilt is rotation about the spine, hip-pivot is rotation about the hip joint). Cue: "Stop pivoting at the hip". Highlights both shoulders. Reuses the lateral-swing quality budget. |
| **Shoulder shrug** (`FormError.shoulderShrug`) | Biceps curl | Vertical (Y-axis) shoulder displacement / torso length > `kShrugThreshold` (0.12). Momentum/trap cheat — lifting shoulders toward ears. Cue: "Keep your shoulders down". Highlights both shoulders. |
| **Back lean** (`FormError.backLean`) | Biceps curl | Excessive backward hyperextension of the trunk > `kBackLeanThresholdDeg` (10°). Cheating by leaning back to shorten the path or leverage torso momentum. Detected via signed angle from vertical, adjusted for user facing direction (nose-relative). Cue: "Don't lean back". Highlights both shoulders + hips. |
| **Elbow drift** (`FormError.elbowDrift`) | Biceps curl | **Front view:** elbow horizontal drift from starting position > `kDriftThreshold` (0.20× torso length). **Side view:** torso-perpendicular projection of `(E − S)` onto `n̂ = (−u_y, u_x)` where `u = (S − H)/|S − H|`, normalised by torso length. The perpendicular projection is invariant to torso lean by construction — a forward stance no longer fakes elbow drift. Magnitude drives the flag; sign (`lastSignedElbowDriftRatio`, positive = elbow on the +n̂ side) is preserved in side-view telemetry (schema v5+) so future analysis can split "elbow forward" vs. "elbow back" cheats without an engine change. |
| **Short ROM — start** (`FormError.shortRomStart`) | Biceps curl | Rep committed with `maxAngleAtStart < activeThresholds.startAngle − kShortRomTolerance` (5°) AND peak side within tolerance. The arm wasn't fully extended before lifting. Cue: "Start from full extension". Highlights both shoulders. Classified in `consumeCompletionErrors` against the `RomThresholds` pushed via `setActiveThresholds` at IDLE→CONCENTRIC (global, warmup, calibrated, or auto-calibrated depending on profile state). |
| **Short ROM — peak** (`FormError.shortRomPeak`) | Biceps curl | Rep committed with `minAngleReached > activeThresholds.peakAngle + kShortRomTolerance` (5°). The classic abandoned rep — didn't reach full flexion. Cue: "Curl all the way up". Highlights both wrists. Takes precedence over `shortRomStart`: a rep that didn't reach peak necessarily didn't also close, and peak is the more actionable shortfall. |
| **Eccentric too fast** | Biceps curl | ECCENTRIC phase < `kMinEccentricSec` (0.8 s). "Dropping" the weight. |
| **Concentric too fast** | Biceps curl | CONCENTRIC phase < `kMinConcentricSec` (0.3 s). "Flinging" the weight — pure momentum, no muscle control. Cue: "Control the lift". |
| **Tempo inconsistent** | Biceps curl | `(max − min) / mean` of the last `kTempoConsistencyWindow` (3) concentric durations > `kTempoInconsistencyRatio` (0.30). Fatigue/form-breakdown leading indicator: the lift is technically in-tempo per rep, but the rep-to-rep variance is wide. Re-armed after `kTempoConsistencyReArmReps` (5) reps — recoverable drift, not a permanent one-shot. Cue: "Keep steady tempo". Decision is made in `onRepEnd` (not `consumeCompletionErrors`) so the `kQualityTempoInconsistencyDeduction` (0.10) hits the same rep's quality score. |
| **Asymmetry — left lag** (`FormError.asymmetryLeftLag`) | Biceps curl (front view only) | Left vs right peak angle `|delta|` > `kAsymmetryAngleDelta` (15°) for `kAsymmetryConsecutiveReps` (3) consecutive reps, and at the emitting rep `left > right` (left arm didn't flex as deeply). Cue: "Left arm is lagging". Highlights left elbow + wrist. |
| **Asymmetry — right lag** (`FormError.asymmetryRightLag`) | Biceps curl (front view only) | Mirror of left-lag: same streak gate, emitting rep has `right > left`. Cue: "Right arm is lagging". Highlights right elbow + wrist. |
| **Shared asymmetry cooldown** | Biceps curl | TTS cooldown for `asymmetryLeftLag` and `asymmetryRightLag` shares one slot via `_cooldownKeyFor` in `workout_screen.dart` — the user perceives a single "asymmetry problem", not two independent errors. |
| **Fatigue** | Biceps curl | Concentric velocity degrading. After `kFatigueMinReps` (6), ratio of last-window average to first-window average exceeds `kFatigueSlowdownRatio` (1.4). |
| **Squat depth** (`FormError.squatDepth`) | Squat | Rep completed without crossing the active `effectiveBottomAngle` (`kSquatBottomAngle` = 90° by default; relaxed to `kLongFemurBottomAngle` = 100° after auto-detection). Cue: "Go deeper". Quality penalty applied via the multiplicative depth factor in `_computeQualityScore`, not as a flat deduction. |
| **Excessive forward lean** (`FormError.excessiveForwardLean`) | Squat | Trunk-from-vertical (signed `atan2(hip.x − shoulder.x, dy)`) > `kSquatLeanWarnDegBodyweight` (45°) for bodyweight or `kSquatLeanWarnDegHBBS` (50°) for high-bar back squat. `+5°` (`kSquatLongFemurLeanBoost`) when the "Tall lifter" Settings toggle is on. Backward lean (negative signed angle) does NOT fire — the signed formula is the fix that prevents false positives for users who lean back as they squat. Cue: "Chest up — keep your back tall". Highlights both shoulders + hips. Per-rep proportional quality penalty up to `kQualitySquatLeanMaxDeduction` (0.20). |
| **Heel lift** (`FormError.heelLift`) | Squat | `(foot_index_y − heel_y) / leg_len_px > kSquatHeelLiftWarnRatio` (0.03). Heel rises above the forefoot in screen space. Cue: "Drive your heels into the floor". Highlights both heels. Per-rep proportional quality penalty up to `kQualitySquatHeelLiftMaxDeduction` (0.10). |
| **Forward knee shift** (`FormError.forwardKneeShift`) | Squat | `(knee_x − ankle_x) / femur_len_px > kSquatKneeShiftWarnRatio` (0.30). **Informational metric only** — no TTS cue, no quality penalty. Visual highlight on knees only (dimmer orange palette to distinguish from active warnings). Surfaced on Summary screen via 5-tier bucket (`Low / Moderate / Notable / High / Very high`). |
| **Hip sag** | Push-up | Shoulder-hip-ankle collinearity deviation > `kHipSagDeviation` (15°). |
| **Push-up short ROM** | Push-up | Rep completed without elbow reaching `kPushUpBottomAngle` (90°). |

### 4.1b Sagittal Sway Detector

`SagittalSwayDetector` (`lib/engine/curl/sagittal_sway_detector.dart`) is the front-view-only depth-swing engine. It produces `FormError.depthSwing` whenever the lifter rocks toward or away from the camera — motion that 2D pose estimation can't measure directly because it projects onto the camera's optical axis.

**Why it exists.** ML Kit Pose returns 2D landmarks. Sagittal motion (forward/back) is depth motion, and depth in a 2D pose can only be inferred from how apparent body geometry changes. Under pinhole projection, in-plane spans scale as `1/Z` and areas as `1/Z²` — so a torso that appears to grow is approaching the camera, and a torso that appears to shrink is moving away. The legacy detector used a single ratio (`|ΔL_torso| / L_baseline > kSwingThreshold`); this detector replaces it with a principled signal-processing pipeline.

**Features (all dimensionless, all scale-invariant):**

- `f₁ = d_s / d_h` — shoulder width / hip width.
- `f₂ = A / d_h²` — torso quadrilateral area / hip width². Primary signal: the `1/Z²` area scaling and `1/Z` hip scaling cancel out the camera distance; only posture/lean contributes.
- `f₃ = L / d_s` — torso vertical extent / shoulder width. Catches hip-thrust cheats that compress the shoulder→hip distance.

**Pipeline (per accepted frame):**

1. **Visibility gate** — drop the frame if any of the four torso landmarks is below `kSagittalMinLandmarkVisibility` (0.5).
2. **1€ Filter** each feature individually (project mandate; never EMA).
3. **Baseline collection** — while the host says `allowBaseline: true` (FSM IDLE / between reps), accumulate the filtered values until `kSagittalBaselineMinFrames` (30) samples exist, then compute `(μᵢ, σᵢ)` per feature. After the window closes, σ continues to adapt slowly with a hard cap at `kSagittalSigmaDriftCap` (1.5×) of the initial baseline σ — prevents fatigue-induced drift from absorbing real form breakdown.
4. **Z-score** each feature against `(μᵢ, σᵢ)`.
5. **Composite** `S(t) = w₁·z₁ + w₂·z₂ + w₃·z₃` with `kSagittalWeightShoulderHipRatio` (0.20), `kSagittalWeightTorsoArea` (0.70), `kSagittalWeightTorsoLengthRatio` (0.10). `f₁` is down-weighted because lat/delt engagement during a clean curl widens the shoulder span 1–3 cm — that rep-correlated noise must not dominate the score.
6. **Velocity** `v(t) = (S(t) − S(t−Δt)) / Δt` using real frame timestamps (not per-frame deltas) so the same threshold works at 30 fps and 60 fps — required by the cross-platform non-regression rule. Frames with `Δt > kSagittalDtAnomalyFactor × median(recentDt)` are rejected (thermal-throttle guard).
7. **Hysteresis classification** — `v > +kSagittalVelocityThreshold` (1.5 σ/sec) for `kSagittalHysteresisFrames` (3) consecutive frames → forward; mirror for backward; otherwise neutral.

**Integration.** `CurlFormAnalyzer` owns one detector instance, resets it on view changes and on session reset, and feeds every front-view `evaluate()` frame **except** when the [Arm-Over-Torso Occlusion Gate](#41c-arm-over-torso-occlusion-gate) trips. Baseline-eligible frames are those where the analyzer has no rep-start snapshot in flight (`_repStartSnapshot == null`) — i.e. between reps. A non-neutral classified direction proposes `FormError.depthSwing`, but the warning is only emitted when the [Head Stability Corroborator](#41d-head-stability-corroborator) confirms the head moved in sympathy with the detected sway. The peak `|compositeZ|` seen during the rep drives the quality deduction in `_computeQualityScore`, scaled from `kSagittalVelocityThreshold` to 2× that and capped at `kQualitySwingMaxDeduction` (0.25, shared with lateral swing).

### 4.1c Arm-Over-Torso Occlusion Gate

`CurlFormAnalyzer._armOccludesTorso(...)` (`lib/engine/curl/curl_form_analyzer.dart`) is the **prevention** layer in the depth-swing defense pipeline. It returns `true` when the curling-arm wrist OR elbow is currently inside the torso bounding box, indicating ML Kit's torso landmarks are likely drifting due to occlusion. When `true`, the analyzer skips `_swayDetector.update(...)` for that frame entirely — no baseline poison, no velocity update.

**Why it exists.** ML Kit's `inFrameLikelihood` confidence does NOT drop when one body part occludes another — the model interpolates from skeleton priors and stays artificially confident. So when the curling arm passes in front of the shoulders/hips, the (x, y) coordinates *drift* a few pixels per frame without their visibilities ever falling, and the [Sagittal Sway Detector](#41b-sagittal-sway-detector) reads the drift as real depth motion. Visibility-gating alone cannot catch this; we need an explicit geometric check.

**Bounding box.** `xMin = min(ls.x, rs.x)`, `xMax = max(ls.x, rs.x)`, `yMin = min(ls.y, rs.y)`, `yMax = max(lh.y, rh.y)`. A joint occludes when `xMin ≤ joint.x ≤ xMax` AND `yMin ≤ joint.y ≤ yMax`. Front view checks both arms; side views check only the camera-facing arm. Reuses `kSagittalMinLandmarkVisibility` (0.5) as the per-landmark visibility floor — same gate the sway detector uses.

**Fail-open.** Returns `false` when any required torso landmark is missing. The gate can only suppress sway-detector input, never make detection more aggressive than the baseline.

### 4.1d Head Stability Corroborator

`HeadStabilityCorroborator` (`lib/engine/curl/head_stability_corroborator.dart`) is the **verification / veto** layer in the depth-swing defense pipeline. When the [Sagittal Sway Detector](#41b-sagittal-sway-detector) fires but the head shows no corresponding motion, the warning is suppressed as occlusion artifact.

**Why the head is the right witness.** The nose (LM 0) and ears (LM 7, 8) sit physically above the shoulders, well outside the arm-over-torso occlusion zone. A *real* sagittal sway moves the whole spine — including the head — so the head's vertical position (`nose.y`) and apparent scale (inter-ear distance) both shift. An *artifact* sway driven by arm-shadow drift leaves the head untouched. Comparing the two signals lets us veto false positives without weakening real-sway detection.

**Two signals, weighted:**
- `nose.y` — direct vertical head position. Dominant signal (`kHeadVerticalWeight` = 0.7) because forward/back rocking in a roughly-fixed camera frame translates almost entirely into vertical nose motion. Z-score is normalized by the baseline torso length so it survives different camera distances.
- Inter-ear distance — 1/Z scale proxy. Secondary signal (`kHeadScaleWeight` = 0.3) because head turn (yaw) also changes ear distance.

**Pipeline mirrors `SagittalSwayDetector`:** 1€-filtered features, baseline window of `kHeadBaselineMinFrames` (30) neutral-pose samples to establish (μ, σ), slow EMA σ adaptation hard-capped at `kHeadSigmaDriftCap` (2.0×) of the initial baseline σ to prevent fatigue-induced drift from swallowing real head motion. Visibility floor is `kHeadCorroborationMinVisibility` (0.6) per landmark.

**Veto rule.** `(kHeadVerticalWeight × |verticalZ| + kHeadScaleWeight × |scaleZ|) ≥ kHeadCorroborationMinZ` (0.6) — head moved enough to corroborate, NO veto, warning fires. Below threshold → veto, warning suppressed (with `debugPrint` telemetry in debug mode for empirical tuning).

**Fail-open contract.** When nose or either ear is below the visibility floor, or when the corroborator's baseline has not yet closed, the analyzer treats the result as "no veto" — the original sway detector's verdict stands. The corroborator can only suppress false positives, never introduce false negatives. Same reset lifecycle as `_swayDetector` — cleared at view change and at session reset.

### 4.2 Quality scoring

| Term | Meaning |
|---|---|
| **Rep quality score** | Per-rep 0–1 score. 1.0 = perfect; deductions subtracted per form error. Proportional — deduction scales linearly from 0 at threshold to max at 2× threshold. |
| **Max deduction** | Per-error cap: swing `kQualitySwingMaxDeduction` (0.25), drift `kQualityDriftMaxDeduction` (0.20), eccentric `kQualityEccentricDeduction` (0.15), concentric `kQualityConcentricDeduction` (0.10), tempo-inconsistent `kQualityTempoInconsistencyDeduction` (0.10), short-ROM `kQualityShortRomDeduction` (0.30), asymmetry `kQualityAsymmetryDeduction` (0.10). |
| **Session quality** | Aggregate score shown on the Summary screen. Average of per-rep scores. |

### 4.3 Cooldowns

| Term | Meaning |
|---|---|
| **Feedback cooldown** | `kFeedbackCooldownSec` (3 s) minimum between visual/voice feedback events. Prevents spam. |
| **Audio cooldown** | Synonym in prose. Implemented via the same constant. |

---

## 5. Pose Pipeline

| Term | Meaning |
|---|---|
| **Pose estimation** | The ML-driven conversion of a camera frame into a list of body landmarks. |
| **ML Kit Pose** | Primary pose backend on mobile. 33 landmarks (BlazePose schema). |
| **MoveNet Lightning** | Fallback pose backend. 17 landmarks (COCO schema). Not currently wired — placeholder for future work. |
| **PoseService** | Abstract interface (`app/lib/services/pose/pose_service.dart`). Implementations: `MlKitPoseService`. |
| **PoseResult** | One frame's worth of landmarks + metadata. Consumed by `RepCounter.onPose()`. |
| **PoseLandmark** | Single landmark: `x, y, z, confidence` (0..1). `visibility` in MediaPipe is renamed to `confidence` on-device (the offline pipeline uses `v` in JSONL to stay visually distinct). |
| **BlazePose schema** | The 33-landmark map used by both ML Kit and MediaPipe. Shared on-device and offline. |
| **1€ Filter** | One-Euro filter. Adaptive low-pass filter for landmark smoothing. Parameters: `kOneEuroMinCutoff` (1.0), `kOneEuroBeta` (0.007), `kOneEuroDCutoff` (1.0). |
| **Landmark smoother** | `LandmarkSmoother` in `engine/landmark_smoother.dart` — applies the 1€ filter per landmark per axis. |
| **3-frame MA** | 3-frame moving average applied to angles (not landmarks) inside the FSM. Independent from the 1€ landmark filter. Offline pipeline deliberately disables MediaPipe's built-in smoothing to avoid double-smoothing. |

---

## 6. Camera & View

| Term | Meaning |
|---|---|
| **CameraService** | Camera pipeline wrapper. Handles platform-specific format (`nv21` on Android, `yuv420` on iOS). |
| **YUV → RGB conversion** | CPU-intensive format conversion. Always use `utils/image_converter.dart`; never roll your own. |
| **Target FPS** | `kTargetFPS` (15) — minimum interactive frame rate. |
| **Camera FPS** | `kCameraFps` (30) — the actual capture rate; pose estimation may drop to target FPS. |
| **End-to-end latency** | `kMaxEndToEndLatency` (200 ms) — capture-to-feedback budget. |
| **Camera view** (biceps curl) | One of `{ unknown, front, sideLeft, sideRight }`. Auto-detected at `setupCheck`, locked for the session unless re-detection fires. |
| **View detector** | `CurlViewDetector` — auto-classifies view from shoulder separation, nose offset, and confidence deltas over `kViewDetectionFrames` (15). Consensus requires `kViewDetectionConsensusFrames` (10). |
| **View redetection hysteresis** | `kViewRedetectHysteresisFrames` (10) — frames a new view must dominate before the lock swaps mid-set. |
| **Side-view shoulder-sep threshold** | `kSideViewShoulderSepThreshold` (0.10) — horizontal shoulder separation below this signals side view. |
| **Front-view shoulder-sep threshold** | `kFrontViewShoulderSepThreshold` (0.15) — above this signals front view. |
| **View-detector hysteresis (`kViewHysteresisDelta`)** | 0.03 — post-lock band that asymmetrically widens the shoulder-separation thresholds during continuous re-detection. Locked on front: need sep ≤ 0.07 (strict − delta) to count toward side evidence. Locked on a side: need sep ≥ 0.18 (strict + delta) to count toward front evidence. Applies only through `CurlViewDetector.classifyFrame(pose, currentLocked: …)`; the initial consensus lock path (`update` → `_tryLock`) uses strict thresholds. Complements the frame-count hysteresis (`kViewRedetectHysteresisFrames`) — one gates on evidence strength, the other on persistence. |
| **Runtime View Re-detection** | Engine-side mechanism in `CurlStrategy` that re-classifies the camera view (`sideLeft`/`sideRight`/`front`) every frame and applies a flip only at FSM idle after `kViewRedetectHysteresisFrames` consecutive agreeing frames. Runs even when the view was pre-seeded by the home-screen picker. When a flip occurs, `onViewFlipped(from, to)` fires; the view-model surfaces a 2-second non-blocking banner so the user sees the system adapt. While `kCurlFrontViewEnabled == false`, a flip *to* front updates `_lockedView` and fires the banner but does NOT switch the analyzer to the front code path. The locked view is **sticky across `onNextSet`/`onReset`** — body orientation persists between sets. |

---

## 7. Session Lifecycle

| Term | Meaning |
|---|---|
| **Session** | A full workout — from app open to Summary screen. May contain multiple sets. |
| **Set** | A contiguous sequence of reps without a long pause. Ends when the user taps "New set" or finishes. |
| **WorkoutPhase** | Enum `{ calibration, setupCheck, countdown, active, completed }`. Top-level lifecycle. |
| **Calibration** | The Personal Calibration phase (see §3.4). Runs only when forced or when no profile exists and the user has not opted out. |
| **Setup check** | Framing + requirements verification. Waits `kSetupCheckFrames` (10) valid frames. Checks that exercise-specific required landmarks have confidence ≥ gate. |
| **Countdown** | `kCountdownSeconds` (3) s pre-workout countdown. |
| **Active** | Reps are counted. |
| **Completed** | Session finished; Summary screen shown. |
| **Absence timeout** | `kAbsenceTimeoutSec` (3 s) — if user disappears for this long, the session auto-completes. |
| **Occlusion prompt** | `kOcclusionPromptSec` (1.5 s) — sustained landmark loss triggers a visual prompt. `kOcclusionResumeFrames` (5) valid frames to clear. |
| **Long-femur detection** | Auto-adjust squat `bottomAngle` for tall users. After `kLongFemurDetectReps` (3) reps below `kLongFemurBottomAngle` (100°), the threshold relaxes. **Orthogonal** to the user-facing **Tall lifter** toggle (which widens the *lean* threshold, not the BOTTOM angle) — the two flags target different gates and never stack on the same one. See `.agent_brain/SKILLS.md §5`. |
| **`SquatVariant`** | `enum { bodyweight, highBarBackSquat }`. User-declared at workout start via the HomeScreen modal sheet; persisted in `PreferencesRepository`. Toggles the lean threshold inside `SquatFormAnalyzer` (45° BW vs 50° HBBS). Variant is fixed for the session — mid-session changes apply on the next workout (snapshot-on-construction). Sheet always opens; dismissal cancels navigation, no workout starts. |
| **Tall lifter (toggle)** | Settings → Squat → "Tall lifter (relax lean threshold)". Adds `kSquatLongFemurLeanBoost` (+5°) to the active lean threshold for users with long femurs / restricted ankle mobility. Read at `WorkoutViewModel.init()`; immutable for the session ("Applies to next workout" subtitle). Independent of the auto-detected long-femur flag. |

---

## 8. Default ROM Threshold Pipeline (offline tool)

> Full documentation: `tools/dataset_analysis/docs/00_overview.md`.

### 8.1 Pipeline phases

| Phase | Name | Input → Output |
|---|---|---|
| **Phase A** | Setup | — → Angle math + index utils ported from app |
| **Phase B (extract)** | Video → Keypoints | `data/videos/*.mp4` → `data/keypoints/*.jsonl` via `extract_keypoints.py` (MediaPipe) |
| **Phase B (annotate)** | Keypoints → Rep boundaries | `data/keypoints/*.jsonl` + `videos.csv` (with `intended_quality`) → `data/annotations/reps.csv` via `phase_b_auto_annotate.py`. Manual VLC-scrubbing is the documented fallback when a clip mixes rep qualities. |
| **Phase C** | Per-rep stats | Keypoints + annotations → `data/derived/per_rep_stats.csv` |
| **Phase D** | Derivation + codegen | Per-rep stats → `data/derived/thresholds.json` → `app/lib/core/default_rom_thresholds.dart` |
| **Phase E** | Replay validation | Keypoints + annotations + real RepCounter → `data/derived/validation_report.md` (F1 gate) |

### 8.2 Pipeline terms

| Term | Meaning |
|---|---|
| **Clip** | A single recorded video. Filename: `clip_{nnn}_{subject_id}_{view}_{side}.mp4`. |
| **Clip ID** | Filename stem (e.g. `clip_042_subj_a_side_right`). Joins across `videos.csv`, `reps.csv`, JSONL. |
| **Keypoints JSONL** | One JSON object per frame: `{frame, t_ms, landmarks: [...]}`. 33 landmarks or `[]` (missing person). |
| **videos.csv** | One row per clip: `clip_id, subject_id, view, side, arm, fps, intended_quality, notes`. Committed. `intended_quality` is optional (blank when annotating reps by hand). |
| **`intended_quality`** | Clip-level quality label used by the auto-annotator to fan out per-rep quality. Values: `good` / `bad_swing` / `bad_partial_rom` / `bad_speed` / blank. Set per-clip at recording time so every rep in the clip shares the same quality (the auto-annotator copies it into every detected rep row). |
| **reps.csv** | One row per rep: `clip_id, rep_idx, start_frame, peak_frame, end_frame, quality`. Committed. Produced by `phase_b_auto_annotate.py` (signal-based) or by hand-scrubbing in VLC (fallback). |
| **Auto-annotation gates** | `min_excursion = 40.0°` and `min_dwell_frames = 8` — mirror the shipping Dart `kCalibrationMinExcursion` and `kRepBoundaryMinDwellFrames`. Guard-tested in `tests/test_auto_annotate.py`. |
| **Rep quality** | Per-rep label on `reps.csv`: `good`, `bad_swing`, `bad_partial_rom`, `bad_speed`. Only `good` feeds percentile math; all reps feed F1 scoring. |
| **Safety margin** | 5° buffer applied to derived thresholds (`SAFETY_MARGIN_DEG = 5.0`). Covers pose noise + user variation. |
| **Bootstrap CI** | 95% confidence interval via 1000-resample non-parametric bootstrap. Seed `1234` (deterministic output). |
| **Percentile gate** | P20 of `start_angle`/`end_angle` for the lower gates, P75 of `peak_angle` for the peak gate. |
| **Peak-exit gap** (offline) | Same 15° as on-device (`CURL_PEAK_EXIT_GAP_DEG`). Added to derived `peak_angle` to produce `peak_exit_angle`. |
| **FSM invariant check** | `check_invariants()` in `derive_thresholds.py`. Exits non-zero on violation; pipeline halts. Mirrors on-device invariants. |
| **Replay harness** | `dart_replay/bin/replay.dart`. Imports the real `RepCounter` via `path:` dep, streams JSONL through it, scores F1. No Python FSM port exists or can exist. |
| **F1 gate** | Overall F1 ≥ 0.95 AND no clip < 0.85. Both must hold to ship new thresholds. |
| **Dataset summary** | Provenance string embedded in generated Dart file: `"N good reps / M total rows across K clip(s)"`. |

### 8.3 Generated artefact

| Term | Meaning |
|---|---|
| **`default_rom_thresholds.dart`** | The single Dart file emitted by the pipeline. Committed. Consumed by the app as the starting thresholds every new user inherits. Since the 2026-04-25 v2 upgrade, emitted by `generate_dart_v2.py` (not the v1 `generate_dart.py`) with per-(view, side) bucket constants plus a `forView()` lookup. |
| **`DefaultRomThresholds`** | The generated class (private constructor). v1 shipped five `static const double` members (pooled). **v2 ships per-bucket constants** (e.g. `frontStartAngle`, `sideLeftStartAngle`, …) plus `peakExitGap` and a static `forView(CurlCameraView)` lookup that returns a `CurlRomThresholdSet`. |
| **`CurlRomThresholdSet`** | Value class in generated Dart: `{ startAngle, peakAngle, peakExitAngle, endAngle }`. Returned by `DefaultRomThresholds.forView(view)`. Lets the FSM pick the correct bucket at runtime without threading view context through every constant access. |
| **Manual ROM override** (`manual_rom_overrides.dart`) | **Highest-precedence tier** of the cold-start threshold resolver. Hand-curated per-view overrides that survive regeneration of `default_rom_thresholds.dart`. Gated by `kUseManualOverrides` (default `true`). Front-view bucket populated 2026-04-26 from a 13-rep diagnostic-mode session: `start=148°, peak=35°, peakExit=50°, end=128°`. Side-view buckets `null` until a side-view session is captured. Three-tier precedence: **override → data-driven (`kUseDataDrivenThresholds`) → legacy constants**. The override file is hand-edited; the generated file remains owned by `tools/dataset_analysis/`. |

### 8.4 Phase D-v2 statistical methodology (2026-04-25)

The v1 derivation (`derive_thresholds.py`) was replaced for shipping use by `derive_thresholds_v2.py` after the T2.4 execution exposed three gaps: (a) pooling side- and front-view reps masks bimodal distributions, (b) naive bootstrap CIs absorb sub-degree biomechanical asymmetries, and (c) hand-picked safety margins are not defensible. v1 retained as baseline for comparison/regression.

| Term | Meaning |
|---|---|
| **Per-(view, side) bucketing** | v2 splits reps by `(view, side)` before computing percentiles. Mirrors the shipping `CurlRomProfile` bucket schema. A bucket needs ≥3 good reps to produce thresholds. |
| **Harrell-Davis percentile** | Weighted average of all order statistics via a Beta(p(n+1), (1-p)(n+1)) kernel. Lower variance than linear interpolation at small n. Reference: Harrell & Davis (1982), *Biometrika*. Pure-Python implementation in `derive_thresholds_v2.py:hd_percentile()`; Beta CDF via Lentz's continued-fraction algorithm. |
| **BCa bootstrap** | Bias-Corrected and accelerated bootstrap 95% CI. Corrects the naive percentile bootstrap for (a) bias `z₀` = fraction of resamples below observed statistic, and (b) acceleration `â` = jackknife-estimated skewness. Reference: Efron & Tibshirani (1993), *An Introduction to the Bootstrap*. Implementation in `bca_bootstrap_ci()`. 10,000 resamples, seed=1234. |
| **MAD outlier rejection** | Reject reps whose (start/peak/end) angle is > 3.5 MADs from the bucket median. Reference: Leys et al. (2013), *JESP*. MAD scaled by 1.4826 for normal-consistent σ. Implementation in `mad_reject_indices()`. |
| **Design effect / ICC** | `DE = 1 + (m-1)ρ` where ρ is the intra-clip correlation coefficient (one-way random-effects ANOVA ICC(1,1)) and m is average reps per clip. Effective n = n / DE. Reference: Kish (1965), *Survey Sampling*. Implementation in `design_effect()`. Collapses to DE = 1.0 when each bucket has only 1 clip (T2.4's case). |
| **Data-driven safety margin** | Replaces the hand-picked 5° constant with `max(5°, min(15°, 2σ_mad))` of the bucket's rest-angle distribution. Floored at 5° to preserve FSM invariants against sub-degree "post-rep overshoot"; ceilinged at 15° to avoid overfitting to noisy datasets. |
| **FSM-safe end-angle adjustment** | When `end_p20 > start_p20` (the post-rep overshoot asymmetry exposed by the tight BCa CIs), the rep-end threshold is substituted with `min(start_p20, end_p20) - margin - 1°` to preserve the `start > end` FSM invariant. Flagged in the generated Dart comment. |
| **LOCO-CV** | Leave-One-Clip-Out cross-validation: for each clip, re-derive pooled thresholds from the remaining clips; report mean ± std of fold estimates. High std (>10°) indicates thresholds don't generalize across clips — used to **justify** per-bucket splitting, not to reject it. |
| **Post-rep overshoot** | A real sub-degree biomechanical asymmetry: the arm extends slightly farther at rep-end than at rep-start (momentum carries it past neutral). Typically 0.1-0.6°. Invisible to naive pooled bootstrap (CIs ~20° wide); visible to BCa-corrected per-bucket bootstrap (CIs ~1° wide). |
| **2D projection dependence** | Front-view MediaPipe angles are geometrically correct 2D projections, not anatomical joint angles. Front-view `peakAngle ≈ 20°` is the 2D angle formed by `shoulder → elbow → wrist` when the wrist overlaps the shoulder in the image plane — NOT "20° of anatomical flexion." Side-view thresholds are anatomically accurate; front-view thresholds only generalize to similar camera setups. Documented in the generated Dart and in WISDOM. |
| **Invariant guard** | The v2 derivation refuses to emit thresholds unless all four FSM invariants pass: `start > peak_exit`, `start > end`, `end > peak_exit`, `peak < start`. Violations raise non-zero exit; the pipeline halts. **This is the primary correctness assertion for T2.4** since the Phase E replay harness was not run (see `T2.4_STATE.md §11.2.3`). |

### 8.5 Pipeline script split (v1 baseline ↔ v2 shipping)

| Artefact | v1 (baseline) | v2 (shipping) |
|---|---|---|
| Derivation | `scripts/derive_thresholds.py` | `scripts/derive_thresholds_v2.py` |
| Codegen | `scripts/generate_dart.py` | `scripts/generate_dart_v2.py` |
| Output JSON | `data/derived/thresholds.json` | `data/derived/thresholds_v2.json` |
| Output Dart | (overwrites same file) | `app/lib/core/default_rom_thresholds.dart` |
| Percentile | Linear interpolation | Harrell-Davis |
| Bootstrap | Naive percentile | BCa |
| Bucketing | Pooled | Per-(view, side) |
| Safety margin | 5° hard-coded | Data-driven 2σ (5-15° bounded) |
| Outlier rejection | None | MAD (threshold 3.5) |
| Cross-validation | None | LOCO-CV |
| Dart output | 5 pooled constants | Per-bucket constants + `forView()` |

v1 remains in the tree for regression testing / teaching. New runs should use v2 unless reproducing a historical threshold set.

---

## 9. Telemetry

| Term | Meaning |
|---|---|
| **TelemetryLog** | In-memory ring buffer. `kTelemetryRingSize` (500) entries. No disk persistence in v1. Surfaced through Settings → Diagnostics. |
| **TelemetryEntry** | One tagged event with timestamp + payload map. |
| **Telemetry tag** | Event type string. Canonical set: `profile.update`, `profile.outlier_rejected`, `profile.shrink_pending`, `calibration.start`, `calibration.complete`, `calibration.fail`, `calibration.skipped`, `rep.thresholds`, `rep.commit_skipped_view_unknown`, `view.switch_deferred`, `view.uncalibrated_notice`, `schema.migration_failed`. Tags are freeform strings but **must** follow the `subject.event` pattern; add new tags to this list in the same PR. |

---

## 10. UI Surfaces

| Term | Meaning |
|---|---|
| **Home screen** | Entry point. Exercise selection + gear icon → SettingsScreen (with coverage badge). |
| **Workout screen** | Main pose-tracking screen. Hosts all phases (calibration → setupCheck → countdown → active → completed). |
| **Summary screen** | Post-session report. Per-exercise layouts. Biceps curl has 7 sections + collapsible Details panel. |
| **Settings screen** | Profile dashboard. Per-bucket indicator, Recalibrate, Reset, Diagnostics. |
| **Calibration overlay** | See §3.4. |
| **Coverage badge** | Colored dot on the home gear icon: red (no buckets / cold start), orange (partial coverage of the 4 main combos), none (all 4 covered). |
| **4 main combos** | `(left, front)`, `(right, front)`, `(left, sideLeft)`, `(right, sideRight)`. The baseline coverage set for biceps curl. |
| **In-workout gear** | AppBar `Icons.tune` action on biceps-curl workouts. Red-dot badge if uncalibrated. Opens a bottom sheet with "Calibrate now" / "Open Settings". |
| **Uncalibrated-view notice** | 2-second banner on mid-set view rotation to an uncalibrated bucket. |
| **Calibration completion card** | 2-second full-screen summary shown between `_completeCalibration` and `setupCheck` so the user registers which bucket was captured. |

---

## 11. Biomechanical Constants (pose-space normalisers)

| Term | Meaning |
|---|---|
| **Torso length** | `|y_hip_mid − y_shoulder_mid|` in normalised (0..1) pose space. The universal normaliser for all horizontal drifts. |
| **L_torso** | Synonym in the academic references / `SKILLS.md`. |
| **Drift (normalised)** | Any `ΔX / L_torso`. Produces unit-free scores suitable for cross-user thresholds. |
| **Shoulder separation** | Horizontal distance between shoulders, normalised by torso length. Used by the view detector. |
| **Nose offset** | Horizontal distance from nose to shoulder midpoint, normalised. Also used by the view detector. |

---

## 12. Engineering Terms

| Term | Meaning |
|---|---|
| **AGENT_DIRECTIVES.md** | Hard rules file at repo root. Verification, edit safety, phased execution. |
| **Brain** | The `.agent_brain/` directory — durable context for Claude across sessions. Seven files: `INSTRUCTIONS, STATE, STRUCTURE, TECH_STACK, ROADMAP, SKILLS, WISDOM, CHANGELOG`. |
| **WP** | Work Package. Major feature grouping (WP1..WP5). Sub-packages numbered `WP4.X` (X = iteration). |
| **T-number** | Task identifier inside a WP (`T4.1`, `T4X.3`). |
| **Vocabulary lock** | A deliberate glossary decision that must not be silently reopened. This file is the registry. Brain `WISDOM.md` explains rationale for locks. |

---

## 13. Language Style Rules

- **Rep** (not "repetition"). Always lowercase in prose unless starting a sentence.
- **Rep count** (not "rep counter") when describing the number; "rep counter" refers to the subsystem / class.
- **Angle** always in **degrees**, never radians. The FSM and all thresholds are degrees.
- **Frame** means one camera frame + its pose result. **Rep** means one contraction cycle. Never conflate.
- **Landmark** (not "keypoint") in on-device code. **Keypoint** is acceptable in the offline pipeline because MediaPipe's naming propagates into JSONL (`keypoints/*.jsonl`).
- **Bucket** always means a `(ProfileSide, CurlCameraView)` entry in `CurlRomProfile`. Never used for non-profile collections.
- **View** always means `CurlCameraView` in biceps-curl context. In squat/push-up context, "view" is not a formal term — don't use it there.
- Use **"on-device"** vs **"offline"** to distinguish phone-runtime from developer-pipeline. Never "online"/"offline" (confuses with network state).

---

## 13b. Local Persistence & History (WP5, 2026-04-25+)

Introduced by WP5.1. The live surface is under `lib/services/db/` and `lib/services/app_services.dart`.

### 13b.1 Persistence types

- **DatabaseService** — App-lifetime singleton that opens and owns the single sqflite `Database` handle for `{docs}/fitrack.db`. Created once in `FiTrackApp.initState` after the DB bootstrap; closed in `dispose` (fire-and-forget). Repositories receive the `Database` via constructor injection; they never reach back into `DatabaseService`. Implementation: `SqfliteDatabaseService` (`services/db/database_service.dart`).

- **ProfileRepository** — Abstract persistence interface for ROM profiles. Concrete impls: `SqliteProfileRepository` (production, backs the `profiles` table, key `curl_profile_v1`) and `InMemoryProfileRepository` (test double). Replaces the deprecated `RomProfileStore`; the four-method surface (`loadCurl`/`saveCurl`/`resetCurl`/`existsCurl`) is preserved 1:1. On corrupt blob / schema mismatch: logs `schema.migration_failed`, deletes the row, returns null — same recovery behavior as the JSON reader it replaces.

- **SessionRepository** — Abstract persistence interface for completed workouts. PR1 ships **interface + `InMemorySessionRepository` stub only**; PR2 adds `SqliteSessionRepository` with `insertCompletedSession` (transactional: one `sessions` row + N `reps` + M `form_errors`). Read methods (`listSessions`, `getSession`, `recentConcentricDurations`) land in PR3/PR4. Shipping the interface in PR1 keeps PR2 additive — `AppServicesScope` doesn't change shape.

- **JsonProfileMigrator** — One-shot idempotent migrator that copies `{docs}/profiles/biceps_curl.json` into the `profiles` row and renames the legacy file to `biceps_curl.json.migrated.backup` (uniquifies with `.N` suffix on collision). Outcomes: `noLegacyFile`, `migrated`, `skippedAlreadyMigrated`, `corruptLegacyFileDropped`. Reads the legacy file directly via `dart:io` — does NOT import the deprecated `rom_profile_store.dart`, so those types stay tree-shaken dead code.

### 13b.2 Domain types (schema-ready; first rows land in PR2)

- **Session** — A single completed workout, committed on `WorkoutPhase.completed`. Persisted as one row in `sessions` + N rows in `reps` + M rows in `form_errors` under a single DB transaction. Schema is exercise-agnostic; curl-only columns (`detected_view`, `side`, `view`, `threshold_source`, `bucket_updated`, `rejected_outlier`) are NULL for squat/push-up. Indefinite retention (user-controlled export/delete is out of WP5 v1 scope).

- **Rep Record** — A single rep within a `Session`. Curl: populates all curl-specific columns (`side=ProfileSide.name`, `view=CurlCameraView.name`, `threshold_source=ThresholdSource.name`, `bucket_updated=0/1`, `rejected_outlier=0/1`). Squat/push-up: only `rep_index` + `quality` populated; curl columns NULL. PR2 writes rows; PR3 reads them back via `RepRow.toCurlRepRecord()` to rebuild `CurlRepRecord` lists for the reconstructed `SummaryScreen`.

- **Fatigue Baseline** — The reference duration the curl analyzer compares against when deciding whether to emit `FormError.fatigue`. As of WP5.4 (2026-04-25), the baseline is `max(in-session first-window avg, 30-day historical median)`. Historical list comes from `SessionRepository.recentConcentricDurations(exercise: bicepsCurl, window: Duration(days: 30))`, hydrated in `WorkoutViewModel.init()` and threaded to `CurlFormAnalyzer` via `CurlStrategy`. Median (not mean) for outlier robustness — a single anomalously-slow prior rep can't poison the baseline. On a user's first-ever curl session the list is empty and the baseline collapses to today's in-session-only value (backward-compat with pre-WP5.4 behavior).

### 13b.3 UI (WP5.3)

- **HistoryViewModel** — `ChangeNotifier` backing the History screen. Owns `filter` (nullable `ExerciseType`, null = all), `loading`, `error`, and `sessions` state. `load()` + `setFilter()` + `deleteSession()`. Per-screen lifetime (disposed on pop). Internal `_disposed` guard swallows any notify that races with a late-resolving async chain.
- **Workout History** — The UI surface (`HistoryScreen`, `SessionCard`, `HistoryDetailLoader`) that lists past `Session`s newest-first and reopens a reconstructed `SummaryScreen` via `SummaryScreen.fromSession(SessionDetail)`. Filter row: `[All · Curl · Squat · Push-up]` chips (plan-locked). Read-only in v1 — no swipe-to-delete or pin.
- **`SummaryScreen.fromSession(SessionDetail)`** — Factory constructor on the existing `SummaryScreen`. Maps persisted `RepRow`s back into `CurlRepRecord`s via `RepRow.toCurlRepRecord()` and forwards into the unchanged named-parameter constructor. `curlBucketSummaries` is passed empty because bucket ring-buffer state is live-only, not persisted.

### 13b.4 Scope plumbing

- **AppServicesScope** — `InheritedWidget` at the `MaterialApp` root (`app/lib/app.dart`) that exposes `DatabaseService` + `ProfileRepository` + `SessionRepository` to descendants. Resolve via `AppServicesScope.of(context)` (registers a dependency) or `AppServicesScope.read(context)` (one-shot read for callbacks / `initState`). Avoids a global `MultiProvider` while still being a single app-lifetime singleton — matches the existing "providers are per-screen" convention.

### 13b.5 Schema & versioning

- **`kDbSchemaVersion`** — 5 as of 2026-04-27 (was 4 after the bicepsCurl-front/side rewrite, 3 after the squat rebuild, 2 in T5.3, 1 across WP5 PRs 1–4). v5 adds 5 nullable columns to `reps`: `biceps_lean_deg REAL`, `biceps_shoulder_drift_ratio REAL`, `biceps_elbow_drift_ratio REAL`, `biceps_back_lean_deg REAL`, `biceps_elbow_drift_signed REAL` — per-rep persistence for the side-view biceps form maxes plus the sign at peak magnitude. v4 rewrote `sessions.exercise = 'bicepsCurl'` rows to `'bicepsCurlFront'`. v3 added 4 nullable squat columns + `squat_variant TEXT`. v2 added `preferences` table + `reps.dtw_similarity REAL` column. Every `onUpgrade` block is additive; legacy installs upgrade cleanly with NULL in new columns. Bump when adding tables or non-NULL-tolerant columns.

- **`biceps_lean_deg / biceps_shoulder_drift_ratio / biceps_elbow_drift_ratio / biceps_back_lean_deg / biceps_elbow_drift_signed`** — Per-rep biceps-curl side-view form maxes, persisted in `reps` (schema v5+). Populated only on `bicepsCurlSide` rows with `view IN (sideLeft, sideRight)`. NULL on front-curl, squat, push-up, and pre-v5 rows. The first four columns hold absolute magnitudes (`_maxLeanDeltaDeg`, `_maxShoulderArcRatio`, `_maxDriftRatio`, `_maxBackLeanDeg`); `biceps_elbow_drift_signed` carries the SIGNED value at the frame where `_maxDriftRatio` peaked, so the retune pipeline can split forward-elbow (positive sign, front-delt cheat) from back-elbow (negative sign, setup issue). Surfaced via [BicepsSideRepMetrics](#bicepsSideRepMetrics) on the completion event and as the five trailing biceps columns in `reps.csv`. Companion live-log line: [`rep.side_metrics`](#repsidemetrics).

- **`rep.side_metrics`** — In-memory `TelemetryLog` line emitted in `_handleCurlRepCommit` after every `bicepsCurlSide` rep with `view ∈ {sideLeft, sideRight}`. Fixed-order key=value tokens (rep, side, view, lean_deg, shoulder_drift_ratio, elbow_drift_ratio, elbow_drift_signed, back_lean_deg, rep_quality, concentric_ms, source). The canonical paste-back format for the side-view threshold retune — joins `rep.extremes` by `rep=N`, but is independently grep-able. Front-view, squat, and push-up reps do not emit it. Designed alongside `biceps_elbow_drift_signed` so live-session telemetry and persistent CSV export carry the same fields with the same precision.

- **`profiles.schema_version`** — Per-row wrapper tag (independent of `CurlRomProfile.schemaVersion` embedded in `profile_json`). Exists so the row-wrapper can evolve separately from the engine's JSON blob.

- **`.migrated.backup`** — Suffix applied to legacy `biceps_curl.json` after successful migration. Collision-safe via `.N` uniquification. User can manually rename back to roll back PR1 on-device.

---

## 13c. DTW Reference Scoring (T5.3, 2026-04-25)

Introduced by T5.3 Layer 1. All terms below are opt-in — the feature is gated behind a `PreferencesRepository` toggle and has no effect on the default workout flow.

| Term | Meaning |
|---|---|
| **DtwScorer** | Pure-Dart class in `engine/curl/dtw_scorer.dart`. Compares two angle traces using Dynamic Time Warping with a Sakoe-Chiba band (width=8). Both series are amplitude-normalized and resampled to 64 samples before comparison. |
| **DtwScore** | Immutable value class: `similarity` (0.0–1.0, clamped) + `rawDistance` (unnormalized, for diagnostics). `similarity = 1 / (1 + raw/64)`. |
| **Sakoe-Chiba band** | DTW path constraint: the warp path may not deviate more than `_kBandWidth = 8` steps from the diagonal. Prevents degenerate alignments (e.g. collapsing the entire candidate onto a single reference point) and keeps complexity O(n × band) rather than O(n²). |
| **Form Match card** | The `SummaryScreen` card that shows `(avg_similarity × 100).round()%` after a session where DTW scoring was enabled. Hidden when `dtwSimilarities` is empty or all-null (toggle was off, or session predates the feature). |
| **ReferenceRepSource** | Abstract interface (`services/reference_reps/reference_rep_source.dart`). `forBucket(CurlCameraView) → List<double>?`. Layer 1 ships `ConstReferenceRepSource`; Layer 2 will introduce `PersonalReferenceRepSource` without touching this interface or the engine. |
| **ConstReferenceRepSource** | Layer 1 concrete impl. Delegates to `DefaultReferenceReps.forBucket(view)`. Returns `null` for `sideRight` and `unknown` (no data yet). |
| **DefaultReferenceReps** | Utility class in `core/default_reference_reps.dart` (private constructor). Holds hand-curated 64-sample median-good-rep angle traces from the T2.4 dataset: `front:both` (n=9) and `side:left` (n=4). A follow-up codegen step will emit this file automatically from Phase D median-good-rep selection. |
| **PreferencesRepository** | Abstract key/value settings interface in `services/db/preferences_repository.dart`. Backed by the `preferences` SQLite table (schema v2). Current keys: `enable_dtw_scoring`. Designed to be reusable for future toggles (TTS, haptics, units). |
| **enable_dtw_scoring** | The `preferences` table key for the DTW toggle. Defaults to `false`. Set via Settings → "Reference Rep Scoring (Beta)" switch. |
| **angle buffer** | `WorkoutViewModel._currentRepAngles` — the per-rep host-side buffer that accumulates `snapshot.jointAngle` values during CONCENTRIC/PEAK/ECCENTRIC phases. Cleared on rep commit and on IDLE→CONCENTRIC. Scored by `RepCounter.scoreCurlRep()` at commit time. Kept in the ViewModel (not the engine) to preserve engine purity (CLAUDE.md hard rule). |
| **Layer 1 / Layer 2** | Layered architecture for reference reps. Layer 1 (shipped): textbook gold-standard via `ConstReferenceRepSource`. Layer 2 (reserved seam): per-user personal reference via `PersonalReferenceRepSource`, backed by a `personal_references` SQLite table, falling back to Layer 1. No engine changes needed for Layer 2. |

---

## 14. Retired / Deprecated Terms

When a term is retired, move its entry here with a `→ replacement` line and the retirement date. Do not delete outright — old commits still reference it.

| Retired term | Retired on | Replacement |
|---|---|---|
| **`FormError.lateralAsymmetry`** (generic "Even out both arms") | 2026-04-21 (Curl Hardening Phase 7 / F6) | `FormError.asymmetryLeftLag` / `FormError.asymmetryRightLag`. The directional split surfaces which arm lagged by preserving the sign of `(left − right)` at the insertion site (the record type `({double left, double right})`). The old generic cue is gone from code; this row is the historical pointer for commits prior to Phase 7. |
| **`FormError.shortRom`** (generic "Full range of motion") | 2026-04-21 (Curl Hardening Phase 8 / F7) | `FormError.shortRomStart` (start not extended enough) / `FormError.shortRomPeak` (peak not deep enough). Classification uses the `RomThresholds` pushed via `setActiveThresholds` at IDLE→CONCENTRIC, compared against numeric extremes captured during the rep and passed through the widened `onAbortedRep({maxAngleAtStart, minAngleReached})`. Peak-short takes precedence. The old generic cue is gone from code; this row is the historical pointer for commits prior to Phase 8. |
| **`CurlRomProfile.calibrationSkipped`** (persisted opt-out flag) | 2026-04-21 (Calibration-Opt-In invariant) | Field removed. With personal calibration now **opt-in only** (never auto-launched), there is no auto-prompt for the user to dismiss, so the persisted opt-out flag has no purpose. `WorkoutScreen._init` enters the calibration phase iff `forceCalibration == true` (the Settings / in-workout-gear entry). `fromJson` silently ignores the legacy key on disk; `toJson` stops writing it. No schema bump — old profiles load without migration. |
| **`FormError.trunkTibia`** (squat trunk-tibia parallelism cue) | 2026-04-25 (Squat Master Rebuild) | `FormError.excessiveForwardLean` (signed, variant-aware). The retired check was a parallelism-deviation rule (`|θ_trunk − θ_tibia| > 15°`) anchored on a single 2-segment proxy; the replacement is an absolute trunk-from-vertical angle with separate thresholds per `SquatVariant` (Bodyweight 45° / HBBS 50°) and a measurement-noise margin from Heliyon 2024 2D-RMSE. **The enum value is RETAINED** so legacy WP5 session rows continue to deserialize via `FormError.values.byName('trunkTibia')` — see `app/test/services/db/legacy_session_compat_test.dart`. New code never emits it; the Summary screen renders pre-rebuild rows under an italicized "Form check (legacy)" subhead, conditional on at least one such row existing. |

---

## 15. Maintenance Duty

- This file is updated in the **same PR** that introduces a new term.
- When the brain's `WISDOM.md` adds a vocabulary-lock entry, mirror it in §1 or add a category here.
- Every quarter, scan the last 3 months of commits for uncovered terms and backfill.
- If this file and the code disagree, **the code wins** — but open a follow-up to decide which should change.
