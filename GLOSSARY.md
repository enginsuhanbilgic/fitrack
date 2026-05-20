# FiTrack Glossary — Project Vocabulary

> **This file is the single source of truth for every FiTrack-specific term.**
> Code, commits, PRs, issues, brain files, chat transcripts, and user-facing
> text must use these exact terms. If you need a new term, add it here first,
> then use it elsewhere.
>
> **Last updated:** 2026-05-13 · **Maintainer duty:** any contributor who
> coins a term is responsible for updating this file in the same PR.

---

## ⚠️ Front-view biceps curl — REMOVED 2026-05-13

Entries below referencing **front-view biceps curl** mechanics (e.g. `CurlFormAnalyzer`, sagittal sway detector, head stability corroborator, depth-swing dual-layer defense, `BicepsFrontRepMetrics`, `frontDefault`/`frontStrict` ROM constants, front-view bilateral commits, `kCurlFrontViewEnabled` feature flag) describe code paths and concepts that no longer exist in the live engine. They are **retained as historical context** so old commits, PRs, and CHANGELOG entries remain readable.

What still lives:
- `ExerciseType.bicepsCurlFront` and `CurlCameraView.front` enum values — `@Deprecated` tombstones; never produced by new sessions but kept so the view-detector fallback sentinel has a valid value.
- SQLite columns `biceps_front_swing_ratio`, `biceps_front_depth_swing_ratio` — NULL on all new writes (SQLite can't drop columns).

If you hit a glossary term and the code it references doesn't exist, check the CHANGELOG entry **[2026-05-13] — Front-view curl removal (Path 1 / Hybrid)** for the deletion details.

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
| **Global Calibration** | The curl Personal-Calibration **save policy**: a single-side calibration whose bucket is duplicated into the opposite side at save time so both arms resolve calibrated thresholds in workouts. Guarded by `_shouldDuplicateToOtherSide` — the duplication is suppressed when the opposite side already holds ≥ `kCalibrationMinReps` samples. | `app/lib/view_models/workout_view_model.dart` (`_completeCalibration`, `_shouldDuplicateToOtherSide`, `_cloneBucketForOtherSide`) | Every first-pass curl calibration completion |
| **Second-Side Calibration** | The optional follow-up pass offered immediately after a first-pass Global Calibration completes. If accepted, runs a second calibration that overwrites only the opposite-side bucket; if declined, the duplicated bucket from pass 1 stands. See `WorkoutViewModel.acceptSecondSideCalibration` / `declineSecondSideCalibration`. | `app/lib/view_models/workout_view_model.dart`, `app/lib/screens/workout_screen.dart` (`_SecondSidePrompt`) | Optional, immediately after first-pass completion |
| **Push-Up Observe-Reps Protocol** | The 2026-05-15 redesign of push-up manual calibration. Replaces the pre-2026-05-15 hold-and-average protocol (`topHold` / `bottomHold` / `rise` stages) where the user statically held the top and bottom positions for 3 seconds each. The new protocol observes [kPushUpCalibrationTargetReps] (=3) valid push-ups via an inline `_PushUpCalibrationRepDetector` that watches the elbow-angle stream for per-rep top/bottom extremes. Each captured pair runs through body-line, in-band, and MAD outlier checks before being added to the buffer. Anchors are `topAnchor = max(kept_tops)` and `bottomAnchor = min(kept_bottoms)`, then passed to `PushUpRomProfile.calibrated`. Rationale: held angles drifted higher than the user's actual rep extremes (held lockout ≠ rep lockout), producing thresholds that real reps couldn't hit. Auto-calibration is permanently disabled (2026-05-15), so this protocol is the only path push-up thresholds get personalised. | `app/lib/view_models/workout_view_model.dart` (`_updatePushUpCalibration`, `_handlePushUpCalibrationFrame`, `_PushUpCalibrationRepDetector`), `app/lib/core/constants.dart` (`kPushUpCalibrationTargetReps`, `kPushUpCalibrationRepTopMinAngle`) | Every push-up calibration session (Settings → Recalibrate push-up, or first push-up workout) |

**Speaking rules:**
- Unqualified "calibration" → assume **Personal Calibration** (the only one users see).
- "Default ROM Threshold" → always means the offline tool. Never abbreviate to "calibration".
- "Auto-calibration" → never stands alone; always understood as a part of Personal Calibration.
- "Global Calibration" is a save-time policy of Personal Calibration, **not** a separate calibration mode the user opts into. The user picks Left or Right; the engine applies the result to both arms. The word "global" describes the bucket-write fan-out, not the data quality.
- "Second-Side Calibration" is always optional — never silently launched. It is the **opt-in** companion to Global Calibration's save policy.
- ❌ Reject: "calibration pipeline" (ambiguous), "user calibration for defaults" (conflated), "two-side calibration" (use **Second-Side Calibration**).

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

### 2.3a Threshold gates (push-up) + hysteresis invariant

| Term | Code constant | Trigger |
|---|---|---|
| **Push-up start angle** | `kPushUpStartAngle` = **150°** | IDLE → DESCENDING (elbow crosses below this) |
| **Push-up bottom angle** | `kPushUpBottomAngle` = 90° | DESCENDING → BOTTOM (elbow crosses below this) |
| **Push-up shallow-rep max** | `kPushUpShallowRepMaxAngle` = 130° | A reversal-before-bottom that reached at least this depth still counts as a shallow rep |
| **Push-up end angle** | `kPushUpEndAngle` = 160° | ASCENDING → IDLE, increments rep count |

**Push-up FSM Hysteresis Invariant** (hard rule, introduced 2026-05-16):
`kPushUpStartAngle (150°) < kPushUpEndAngle (160°)` — strictly, by ≥ a
gate-gap. The **rep-commit gate** (`endAngle`, ASCENDING→IDLE) and the
**next-rep-arm gate** (`startAngle`, IDLE→DESCENDING) must never be equal.
Before 2026-05-16 both were 160°; the absent dead-band let 1€-filtered elbow
jitter at lockout re-arm a just-committed rep, double-counting one physical
push-up (the *double-count bug*). The 10° dead-band makes lockout jitter
unable to re-trigger. Mirrors curl's `start > end` and squat's
`kSquatProfileStartMargin (10°) > kSquatProfileEndMargin (5°)`. Every tier
transform (sensitivity post-pass, calibration derivation in
`PushUpRomProfile.thresholds`) MUST preserve `startAngle < endAngle`;
the calibration `end` gate is clamped to
`[start + kPushUpProfileMinGateGap, max(start+gap, topAngle−gap)]` so the
pre-fix `end = start` collapse is structurally impossible. Regression-guarded
by `push_up_strategy_test.dart` (group *"lockout-jitter double-count
regression"*) and `push_up_rom_profile_test.dart`. See WISDOM 2026-05-16,
`SKILLS.md §6`.

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
startAngle    = observedMaxAngle - kProfileStartTolerance  (5°)
peakAngle     = observedMinAngle + kProfilePeakTolerance   (7.5°)
peakExitAngle = peakAngle        + kCurlPeakExitGap        (15°)
endAngle      = observedMaxAngle - kProfileEndTolerance    (12.5°)
```

Warmup (first `kProfileWarmupReps` = 2 reps of every set): all
tolerances multiplied by `kProfileWarmupMultiplier` = 1.5.

#### Worked example — calibrated peak of 69°

A calibration session that records `observedMin = 69°` (deepest measured
flex) and `observedMax = 160°` (most-extended measured rest) produces the
following gates. **None of them is the raw 69° — the system always gives
the user a cushion** so day-to-day variability, fatigue, and ML Kit pose-
estimation noise (±2-3°) don't quietly tighten the bar.

| Layer | Peak gate user must clear | Notes |
|---|---|---|
| Observed at calibration | 69° | The user's measured deepest flex |
| + `kProfilePeakTolerance` (7.5°) | **76.5°** | High sensitivity, normal reps |
| + warmup multiplier (1.5×) on tolerance | **80.25°** | High sensitivity, first 2 reps of a set |
| + Medium post-pass delta (+12°) | **88.5°** | Medium sensitivity, normal reps |
| + both (Medium + warmup) | **92.25°** | Medium sensitivity, first 2 reps of a set |

The system **never** lowers the gate below the observed peak — the
multiplier and post-pass deltas can only loosen, never tighten. If the
observed bucket is so restricted that the raw math would violate FSM
ordering (`start > end > peakExit > peak`), the resolver clamps `end`
upward (`rom_thresholds.dart:_build`) until completability is restored.
Same `Sensitivity Post-Pass` applies at all three tiers (calibrated,
auto-cal, cold-start), so Coaching strictness is comprehensive across
tiers — see the `Sensitivity Post-Pass` entry.

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

### 3.4a Side-pick contract (curl)

Curl calibration is an **explicit two-step contract**. It binds Global Calibration (the save-time fan-out) to Second-Side Calibration (the optional follow-up).

| Term | Meaning |
|---|---|
| **Side-pick panel** | The Left/Right picker shown by `CalibrationOverlay` while `chosenSide == null`. Renders in place of the rep dots / live angle. The Skip and Retry actions are hidden until a side is picked — committing a side is a precondition for the timeout to start. |
| **`pickCalibrationSide(ProfileSide)`** | VM method invoked when the user taps Left or Right. Arms the `RepBoundaryDetector` and starts the calibration timeout — both are **deferred** until this call so the user can read the prompt without burning calibration seconds. |
| **First pass** | The chosen-side calibration that runs from `pickCalibrationSide` through `_completeCalibration`. On success the bucket is saved AND duplicated to the opposite side per Global Calibration. The host then renders `_SecondSidePrompt` instead of auto-dismissing. |
| **Second pass** | The optional Right-or-Left run that follows when the user accepts the prompt via `acceptSecondSideCalibration`. The detector + timeout are re-armed for the opposite side; on completion only that side's bucket is overwritten (no further duplication). Tracked by `_calibrationSecondPassActive`. |
| **`declineSecondSideCalibration`** | The "No, use globally" exit. Runs the legacy 2 s post-summary exit path — the duplicated bucket from pass 1 stands. |
| **Anatomical Left / Right (calibration)** | The `Left arm` button maps to `ProfileSide.left`. The home-screen mirroring quirk does **not** apply here: calibration concerns the limb being curled, and `curl_strategy.dart` attributes commits by ML Kit anatomical side. |

**Why duplicate at save instead of fall back at read?** The threshold resolver (`_resolveThresholds`) stays free of fallback logic — both `(left, view)` and `(right, view)` keys hold a real bucket after pass 1, so `ThresholdSource.calibrated` flows through diagnostics and telemetry uniformly. The alternative — "missing-side falls back to opposite-side bucket at read time" — would have meant special cases in every caller of `bucketFor`, including telemetry tagging and the bucket-summary UI.

**Why a guard on duplication?** A user who later recalibrates one side must not silently overwrite a previously-dedicated calibration of the other side. `_shouldDuplicateToOtherSide(chosen, view)` returns `false` whenever the opposite-side bucket already holds ≥ `kCalibrationMinReps` samples — that bucket represents real user data, and the new single-side calibration is treated as side-specific.

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
| **Shared asymmetry cooldown** | Biceps curl | TTS cooldown for `asymmetryLeftLag` and `asymmetryRightLag` shares one slot via `_cooldownKeyFor` in `workout_view_model.dart` — the user perceives a single "asymmetry problem", not two independent errors. NOTE the *voice cap* and its *persistence re-arm* are keyed by the **actual error** (not the shared cooldown key), so L-lag and R-lag still mute/re-arm independently. |
| **TTS Verbosity** (`TtsVerbosity`) | All exercises (curl impl. today) | User-selected voice-coaching level: `high` (uncapped), `medium` (default, cap `kTtsVerbosityMediumCap` = 3), `low` (cap `kTtsVerbosityLowCap` = 1). The per-error per-session cap mutes repeat audio for an error once its cooldown-clears exceed the cap. **Persistence re-arm (2026-05-16):** `medium`/`low` no longer go *permanently* silent — a persistent fault re-alerts once every `kTtsPersistenceReArmRepsMedium` (5) / `kTtsPersistenceReArmRepsLow` (8) further muted cooldown-clears (≈ that many more faulty reps, since the 3 s cooldown ≈ 1 fire/rep), then re-mutes. A user who fixes the fault never hears it again (streak stops advancing); a stuck user is periodically re-nudged. Audio-only — `errorCounts`, highlights, summary unaffected. Orthogonal to `FeedbackSensitivity` (strictness) and `Form Tolerance Percent` (dead-band). Lives entirely in `_onFormErrors`; mirrors the `Tempo inconsistent` re-arm shape. |
| **Fatigue** | Biceps curl | Concentric velocity degrading. After `kFatigueMinReps` (6), ratio of last-window average to first-window average exceeds `kFatigueSlowdownRatio` (1.4). |
| **Squat depth** (`FormError.squatDepth`) | Squat | Rep completed without crossing the active `effectiveBottomAngle` (`kSquatBottomAngle` = **80°** as of 2026-05-16 — tightened from 90°/parallel to below-parallel; **PROVISIONAL, telemetry-pending**; relaxed to `kLongFemurBottomAngle` = 100° after auto-detection). The long-femur rep-history detection band is anchored to `kSquatLongFemurDetectFloorAngle` = 90° (NOT `kSquatBottomAngle`) so tightening the depth gate doesn't widen long-femur detection. Cue: "Go deeper". Quality penalty applied via the multiplicative depth factor in `_computeQualityScore`, not as a flat deduction. |
| **Excessive forward lean** (`FormError.excessiveForwardLean`) | Squat | Trunk-from-vertical (signed `atan2(hip.x − shoulder.x, dy)`) > `kSquatLeanWarnDegBodyweight` (30° as of the 2026-05-15 retune; the older 45° figure is stale-drift elsewhere in this doc) for bodyweight or `kSquatLeanWarnDegHBBS` (35°) for high-bar back squat. `+5°` (`kSquatLongFemurLeanBoost`) when the "Tall lifter" Settings toggle is on. **Sustained-frame gate (Phase 1, 2026-05-16):** the verdict is NO LONGER per-frame — `evaluate()` only accumulates per-rep counters; the error is emitted ONCE at rep commit iff `leanExceedFrameCount / leanTotalEvalFrameCount ≥ kSquatLeanSustainedFraction` (0.35) AND `leanTotalEvalFrameCount ≥ kSquatLeanMinEvalFrames` (6, fail-open floor). A single noisy over-threshold frame at the bottom of an otherwise-good rep no longer false-fires. Backward lean (`FormError.excessiveBackwardLean`) KEEPS its instantaneous per-frame fire — lumbar hyperextension is a genuine single-frame injury vector. Cue: "Chest up — keep your back tall". Highlights both shoulders + hips. Per-rep proportional quality penalty up to `kQualitySquatLeanMaxDeduction` (0.20) — unchanged by Phase 1 (reads `_maxLeanDeg`, independent of the verdict gate). `kSquatLeanSustainedFraction` **PRELIMINARY** — retune via the `squat.rep lean_exceed_frac=` telemetry channel. |
| **Heel lift** (`FormError.heelLift`) | Squat | `(foot_index_y − heel_y) / leg_len_px > kSquatHeelLiftWarnRatio` (0.03). Heel rises above the forefoot in screen space. Cue: "Drive your heels into the floor". Highlights both heels. Per-rep proportional quality penalty up to `kQualitySquatHeelLiftMaxDeduction` (0.10). |
| **Forward knee shift** (`FormError.forwardKneeShift`) | Squat | `(knee_x − ankle_x) / femur_len_px > kSquatKneeShiftWarnRatio` (0.30). **Informational metric only** — no TTS cue, no quality penalty. Visual highlight on knees only (dimmer orange palette to distinguish from active warnings). Surfaced on Summary screen via 5-tier bucket (`Low / Moderate / Notable / High / Very high`). |
| **Hip lead** (`FormError.hipLead`) | Squat | "Stripper Squat" / "Good Morning Squat" — during the first `kHipLeadAscendingWindowFraction` (0.30) of ASCENDING, `mean(v_y_hip) / mean(v_y_shoulder) > kHipLeadVelocityRatio` (1.4). Hip rises faster than the shoulder, so the chest collapses forward. Cue: "Lead with your chest". Highlights both shoulders + hips. Per-rep proportional quality penalty up to `kQualitySquatHipLeadMaxDeduction` (0.15). Source: deep-research biomechanical spec, 2026-05-13. |
| **No knee flexion** (`FormError.noKneeFlexion`) | Squat | Torso-pivot-only descent. Fires at rep completion when peak lean `_maxLeanDeg ≥ kSquatNoKneeFlexionMinLeanDeg` (25°) AND knee delta `(_startKneeAngle − _minKneeAngle) < kSquatNoKneeFlexionMaxKneeDeltaDeg` (20°). Distinguishes "leaning forward instead of squatting" from a deep squat with appropriate lean. Planned cue (not yet wired in this PR): "Sit into the squat — bend your knees". Added 2026-05-15. **Thresholds PRELIMINARY** — awaiting telemetry-derived tuning via the standard derive-from-telemetry workflow. |
| **Hips forward on descent** (`FormError.hipsForwardOnDescent`) | Squat | Hip drifted toward the toes (instead of hinging back) within the first `kSquatHipsForwardWindowMs` (200 ms) of DESCENDING. Computed as `(hip.x[t=window] − hip.x[t=0]) × forwardSign / leg_len_px > kSquatHipsForwardMinRatio` (0.05); `forwardSign` is normalized from the initial sign of `(hip.x − heel.x)` so the detector works on both side views. Planned cue: "Push your hips back". Added 2026-05-15. **Thresholds PRELIMINARY**. |
| **Knee-led descent** (`FormError.kneeLedDescent`) | Squat | Knee-dominant (quad-dominant) initiation. Over the SAME early-descent window as `hipsForwardOnDescent` (`kSquatHipsForwardWindowMs`, 200 ms — shared `_descentStartTime`, no second timer), the knee's horizontal travel out-paced the hip's vertical drop: `(|Δknee.x| / leg_len) / (Δhip.y_down / leg_len) > kSquatKneeLedMinRatio` (1.2). The industry-standard "sit back into the squat" rule (NSCA/ACSM movement screening) — the genuine fault the retired "knees must not pass toes" myth gestured at. Cue: "Sit back — lead with your hips, not your knees". Fail-open below `kSquatKneeLedMinFrames` (3) samples. Added 2026-05-16 (Squat Form Audit accuracy rebuild, Phase 2). **CUE-ONLY** — no quality-score deduction until telemetry validates the detector (decision 2026-05-16). **Thresholds PRELIMINARY** — retune via the `squat.knee_led ratio=` telemetry channel. |
| **Knee-dominant pattern** (`FormError.kneeDominantPattern`) | Squat | Compound fault — fires at rep commit ONLY when peak `forwardKneeShift` (`_maxKneeShiftRatio > kneeShiftWarnRatio`) AND peak `heelLift` (`_maxHeelLiftRatio > heelLiftWarnRatio`) BOTH occurred in the same rep. Knee-past-ankle alone is informational (`forwardKneeShift`); the conjunction with heel-lift is the recognized ankle-dorsiflexion-restriction / quad-dominance red flag. Cue: "Keep your heels down and weight mid-foot". Added 2026-05-16 (Phase 3). **CUE-ONLY** — no quality-score deduction (the only quality delta is the pre-existing shared heel-lift path; decision 2026-05-16). |
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

### 4.1e Hip-Lead Detector

Squat-only detector that catches the "Stripper Squat" / "Good Morning Squat" pattern: the hips rise faster than the shoulders during the start of ASCENDING, so the chest collapses forward even as the rep technically completes.

**Why it lives inside `SquatFormAnalyzer`.** The detector reuses the analyzer's per-frame `evaluate(pose, now:)` cadence and its camera-side picking rule, so the buffered samples follow the same confidence + visibility gates as lean / heel-lift. Three new lifecycle hooks (`onDescendingStart` / `onAscendingStart` / `onAscendingEnd`) mirror curl's `onRepStart` / `onPeakReached` / `onEccentricStart` / `onRepEnd` pattern. `SquatStrategy` fires the hooks at FSM transitions — the analyzer never infers phase from raw poses.

**Window math.** `windowSize = max(kHipLeadMinAscendingFrames (6), round(frames × kHipLeadAscendingWindowFraction (0.30)))`. Only frames in the first 30 % of ASCENDING are evaluated because by mid-ascent the spine straightens out naturally even on a hip-lead rep.

**Velocity formula.** `velocity = -(y[i] − y[i-1])` because screen-Y=0 is at the top, so "rising" physically means `y` decreases. The sign-inversion produces POSITIVE values for ascent. The ratio `mean(v_y_hip) / mean(v_y_shoulder)` is sign-invariant under a global flip of this formula, so the contract is locked by two tests that assert on `lastRepHipMeanVelocity` / `lastRepShoulderMeanVelocity` directly (one for ASCENDING → positive, one for descending → negative).

**Fail-open at three places:**
1. Fewer than `kHipLeadMinAscendingFrames` (6) raw frames buffered → skip the check.
2. Pairwise filter drops stationary-shoulder pairs (`|dShoulder| < 1e-6`); if fewer than 4 valid pairs survive → skip.
3. `meanShoulder.abs() < 1e-6` after the per-pair filter → skip (defensive belt-and-suspenders for pathologically-balanced signals).

**Fires** `FormError.hipLead` when `ratio > kHipLeadVelocityRatio` (1.4). Quality deduction: severity `= ((ratio − 1.4) / 0.6).clamp(0, 1) × kQualitySquatHipLeadMaxDeduction (0.15)`, applied multiplicatively in `_computeQualityScore` AFTER lean and heel-lift. TTS cue: "Lead with your chest" with the standard 3 s cooldown.

**Per-rep state lifecycle.** `_ascendingFrames` cleared at `onDescendingStart` (called from `onRepStart`); accumulated during ASCENDING when `_ascendingPhaseActive == true`; drained by `onAscendingEnd` BEFORE `consumeCompletionErrorsWithDepth(...)` reads the flag. The ordering is load-bearing — calling `consumeCompletionErrorsWithDepth` first would lose the error.

### 4.1f Knee-Led-Descent Detector (Phase 2, 2026-05-16)

Squat-only detector for knee-dominant (quad-dominant) initiation — the genuine fault behind the user's "knee must not pass toes" instinct, which is itself a retired myth (`FormError.forwardKneeShift` remains informational-only). This is the industry-standard "sit back into the squat" rule (NSCA/ACSM movement screening).

**Shares the hips-forward descent window — NO second timer.** `_maybeSampleKneeLedDescent` reuses the exact `_descentStartTime` / `kSquatHipsForwardWindowMs` (200 ms) machinery that `_maybeSampleDescentHipX` opens. Called from `evaluate()` immediately after the hip-X sampler. It keys its own anchor off `_descentStartKneeX == null` (not `_descentStartTime`) so call ordering with the hip-X sampler is irrelevant — whichever opens the shared timer first, this sampler captures its own knee.x / hip.y anchor on the same frame.

**Ratio math.** At window close: `ratio = (|Δknee.x| / leg_len) / (Δhip.y_down / leg_len)` where `Δknee.x = lastKneeX − startKneeX` (absolute — direction-agnostic) and `Δhip.y_down = lastHipY − startHipY` (positive on a real descent; screen-Y increases going down). The denominator is clamped at `1e-6` so a near-zero hip drop (shallow rep, already caught by `squatDepth`) cannot explode the ratio into a false positive. The leg-length normalizers algebraically cancel but are written explicitly to mirror the plan's "normalized by leg length" contract.

**Fail-open** below `kSquatKneeLedMinFrames` (3) samples in the window, or on degenerate (`< 1e-6`) leg length → null ratio, no fault. Kept as its own constant (not aliased to `kSquatHipsForwardMinFrames`) so telemetry can retune the two detectors independently.

**Fires** `FormError.kneeLedDescent` when `ratio > kSquatKneeLedMinRatio` (1.2). **CUE-ONLY** — `_computeQualityScore` does NOT read the knee-led signal; the numeric grade and historical quality trends are untouched until telemetry validates the detector (decision 2026-05-16). TTS cue: "Sit back — lead with your hips, not your knees".

**Telemetry.** Secondary `squat.knee_led` line (mirrors `squat.hip_lead`): `rep= ratio= window_frames= threshold=`. `window_frames` is `_kneeLedSampleCount` plumbed analyzer → strategy → `RepCounter.squatKneeLedSampleCount` → `WorkoutViewModel`.

### 4.1g Knee-Dominant-Pattern Compound Fault (Phase 3, 2026-05-16)

Pure rep-boundary conjunction over the already-tracked per-rep maxima — no sampler, no window. Emits `FormError.kneeDominantPattern` iff `_maxKneeShiftRatio > kneeShiftWarnRatio` AND `_maxHeelLiftRatio > heelLiftWarnRatio` in the same rep. Rationale: knee-past-ankle alone is informational (the retired-myth signal); forward knee travel WITH the heel coming up is the recognized ankle-dorsiflexion-restriction / quad-dominance red flag. **CUE-ONLY** — the only quality delta is the pre-existing shared heel-lift deduction; `kneeDominantPattern` itself adds nothing (regression-guarded by a test comparing compound-rep quality against a heel-lift-only rep). `FormError.forwardKneeShift` is left exactly as-is (informational, per-frame, no TTS). TTS cue: "Keep your heels down and weight mid-foot".

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
| **Push-up landscape (OS-coherent scoped rotation)** | Push-up sessions may run with the phone physically rotated to landscape. The push-up `WorkoutScreen` unlocks `[portraitUp, landscapeLeft, landscapeRight]` via `SystemChrome` in `initState`, restores `[portraitUp]` in `dispose` (every exit path destroys the State). The OS rotates UI + camera + capture buffer together, so ML Kit's `size`↔`rotation` stay consistent and the legacy `_camera.sensorRotation` is correct in every orientation. Curl/squat screens never call `SystemChrome` → portrait-locked, unchanged. Preview sizing is `MediaQuery.orientation`-driven (portrait = legacy swapped dims byte-for-byte). |
| **`allowsLandscape`** | `ExerciseType` getter — `true` for `pushUp` only. Gates the `SystemChrome` orientation unlock/restore in the push-up `WorkoutScreen`. Curl/squat (`false`) never touch orientation → byte-for-byte portrait. The sole surviving piece of the original engine-only attempt. |
| **Engine-only rotation (REVERTED 2026-05-16)** | Abandoned approach: kept the UI portrait-locked and fed ML Kit an accelerometer-computed rotation (`computeEffectiveRotation`, `deviceDegFromGravity`, `_committedDeviceDeg`, `PlatformConfig.engineComputesRotation`). Failed three on-device iterations — iOS rotates the capture buffer while the declared rotation stayed static (probe-proven), so ML Kit got a mislabeled frame and detected no body. Replaced by *Push-up landscape (OS-coherent scoped rotation)* above. `services/camera_orientation.dart`, its 26 tests, and the `sensors_plus` dependency were **deleted** in the same change — no dormant rotation code remains. See WISDOM 2026-05-16. |
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
| **`pipeline_rom_defaults.dart`** | The Dart file emitted by the offline statistical pipeline. **SHELVED as of 2026-05-13** — preserved in the tree but not consumed at runtime (gated by `kUsePipelineRomDefaults`, default `false`). Renamed from `default_rom_thresholds.dart` when the project convention shifted to telemetry-derived defaults. Since the 2026-04-25 v2 upgrade, emitted by `generate_dart_v2.py` with per-(view, side) bucket constants plus a `forView()` lookup. |
| **`PipelineRomDefaults`** | The generated class (private constructor) in `pipeline_rom_defaults.dart`. Tier 2 (shelved) in the resolver. **v2 ships per-bucket constants** (e.g. `frontStartAngle`, `sideLeftStartAngle`, …) plus `peakExitGap` and a static `forView(CurlCameraView)` lookup that returns a `CurlRomThresholdSet`. Renamed from `DefaultRomThresholds` on 2026-05-13. |
| **`CurlRomThresholdSet`** | Value class: `{ startAngle, peakAngle, peakExitAngle, endAngle }`. The shared output type of all three resolver tiers — telemetry, pipeline, and legacy all return this same shape, so the resolver consumes them identically. Lives in `pipeline_rom_defaults.dart` for historical reasons. |
| **`CurlRomDefaults`** (`curl_rom_defaults.dart`) | **PROJECT CONVENTION** — the canonical cold-start ROM source for the **biceps-curl FSM**. Tier 1 in the resolver, gated by `kUseTelemetryRomDefaults` (default `true`). Values are derived from **live in-app diagnostic-session telemetry** (the "Curl debug session" Settings toggle records `rep.extremes`; the team post-processes those into the constants in this file). Front-view bucket populated 2026-04-26 from a 13-rep session: `start=148°, peak=35°, peakExit=50°, end=128°`. Side-view buckets populated 2026-04-28. **History:** named `ManualRomOverrides` / `manual_rom_overrides.dart` until 2026-05-13 (am), `TelemetryRomDefaults` / `telemetry_rom_defaults.dart` until 2026-05-13 (pm), then renamed to `CurlRomDefaults` / `curl_rom_defaults.dart` when the per-exercise file split landed (file names follow the *exercise*, provenance lives in the doc-block). |
| **`SquatRomDefaults`** (`squat_rom_defaults.dart`) | Per-exercise ROM defaults for the **squat FSM**. Created 2026-05-13. View-object class wrapping `kSquat{Start,Bottom,End}Angle` from `constants.dart` (provenance: hand-tuned, literature-anchored — values come from `SQUAT_MASTER_SPEC.md`, not telemetry). Pairs with `SquatRomThresholdSet { startAngle, bottomAngle, endAngle }`. Variant-agnostic today; `forVariant(SquatVariant)` returns the same `defaults` regardless of variant. Per-variant differences appear in `SquatStrategy.effectiveBottomAngle` (long-femur auto-detection) and `squat_form_thresholds.dart` (form errors), NOT in the ROM gates. When telemetry-derived squat thresholds arrive, this file will host them. |
| **`PushUpRomDefaults`** (`push_up_rom_defaults.dart`) | Per-exercise ROM defaults for the **push-up FSM**. Created 2026-05-13. View-object class wrapping `kPushUp{Start,Bottom,End,ShallowRepMax}Angle` from `constants.dart` (provenance: hand-tuned, with personal-calibration override at runtime via `PushUpRomProfile`). Pairs with `PushUpRomThresholdSet { startAngle, bottomAngle, endAngle, shallowRepMaxAngle }`. The defaults are used only as the **pre-calibration fallback** — once a user completes push-up calibration, the FSM consumes a per-user `PushUpRomThresholds` derived from their measured top/bottom extremes. Calibration acceptance bounds (`kPushUpCalibration*`) and profile margins (`kPushUpProfile*`) intentionally remain in `constants.dart` — they're infrastructure parameters, not ROM gate values. |
| **Per-exercise `*_rom_defaults.dart` convention** | Each exercise has its own `<exercise>_rom_defaults.dart` file under `app/lib/core/`. **File naming follows the exercise**, provenance is documented in each file's doc-block. Three files today: `curl_rom_defaults.dart` (telemetry-derived), `squat_rom_defaults.dart` (hand-tuned + literature), `push_up_rom_defaults.dart` (hand-tuned + personal calibration). When adding a new exercise: create `lib/core/<exercise>_rom_defaults.dart` mirroring the curl pattern (a `<Exercise>RomThresholdSet` shape class + a `<Exercise>RomDefaults` view-object with a `forX()` lookup) and wire it into the resolver. Established 2026-05-13. |
| **Project convention: telemetry sourcing** | Per the 2026-05-13 convention, FiTrack derives all cold-start ROM thresholds from **live in-app diagnostic-session telemetry**, not from offline video-clip analysis. This applies to **all exercises**, present and future. When a new exercise gets data-derived thresholds, the workflow is: (a) add a debug-session toggle to its Settings panel that emits `rep.extremes` telemetry, (b) record sessions, save the paste under `tools/dataset_analysis/data/telemetry/sessions/`, (c) run the derivation script — auto-saves derived report to `data/telemetry/derived/`, (d) paste the Dart snippet block into the per-exercise `<exercise>_rom_defaults.dart` file. The offline pipeline at `tools/dataset_analysis/` is **shelved**, not removed — re-enable via `kUsePipelineRomDefaults` if/when the recorded dataset becomes large and diverse enough to produce stable cross-validated thresholds. |

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
| Output Dart | (overwrites same file) | `app/lib/core/pipeline_rom_defaults.dart` (shelved 2026-05-13) |
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
| **Summary screen** | Post-session report. **Unified structure (2026-05-13):** every exercise renders the same shared widget sequence (hero → stats grid → variant chips → form audit → form issues → insights → curl-only tails → actions). Slot data comes from `SessionSummaryViewModel`. Adding a new exercise is one factory plus an enum value. |
| **SummaryHero** | `widgets/summary/summary_hero.dart`. The top hero of every Session Complete page — exercise name, large quality %, grade pill, subtitle. **Cardless glass redesign (2026-05-13):** rewritten without a surrounding card surface (no border, no fill, no left-edge cyan strip). A barely-visible radial cyan halo behind the score replaces the card chrome. **"AI FORM ACCURACY" label removed** along with the `Icons.memory_rounded` chip; the label now reads simply `FORM ACCURACY`. Grade pill (translucent cyan fill + thin border) is retained as a compact glyph, not a card. Previous shape (uniform `Border.all` + `Positioned` cyan strip via `FtAccentCard` pattern) is gone — earlier paint-safety doc lives in `CHANGELOG.md` 2026-05-13. |
| **SummaryStatsGrid** | `widgets/summary/summary_stats_grid.dart`. Three-column Time / Reps / Sets tile row directly under `SummaryHero`. Replaces three pre-unification widgets (`_StatChip`, `_StatRow`, `_SummaryStatCard`+`_SetsChip`). |
| **SummaryVariantChips** | `widgets/summary/summary_variant_chips.dart`. Exercise-variant chip row. Today populated only for squat (variant + tall-lifter). Empty list → `SizedBox.shrink()`. |
| **SummaryFormIssuesCard** | `widgets/summary/summary_form_issues_card.dart`. Unified form-error chip wrap. Replaces `_buildSquatFormIssuesCard` and the inline curl form-issues block. Caller filters errors per exercise. |
| **SummaryInsightsCard** | `widgets/summary/summary_insights_card.dart`. "Coaching Insights" bulleted card. Push-up adopted this card in 2026-05-13 unification — it previously had no insights section. |
| **SummaryActions** | `widgets/summary/summary_actions.dart`. Bottom Done button. Identical across exercises post-unification. |
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
| **FeedbackSensitivity** | `enum FeedbackSensitivity { high, medium }` in `core/types.dart`. **Sensitivity vs Form Audit doctrine (2026-05-14, PR A)** — controls **only ROM gates** (post-pass at every tier: calibrated, auto-calibrated, cold-start). Form-audit thresholds (squat lean / shift / lift; curl form gates) are fixed by doctrine and DO NOT consume this enum — see `Form Audit` entry and `.agent_brain/SKILLS.md`. High = identity on the High anchor; Medium = High + per-tier looseness deltas (reproduces today's Medium-baseline numbers bit-for-bit at Tier 1 telemetry and Tier 3 cold-start; at bucket-derived tiers Medium now also loosens). Persisted via `preferences` table key `feedback_sensitivity`. The two-tier contract is anchored at the Dart enum level by `app/test/core/feedback_sensitivity_test.dart`. |
| **Form Audit** | The set of fault detectors that flag biomechanically risky movement patterns during a rep (squat lean, knee shift, heel lift; curl depth-swing, occlusion, head corroborator; push-up form metrics as they're added). Independent of `FeedbackSensitivity` by doctrine — see `.agent_brain/SKILLS.md` "Sensitivity vs Form Audit" (2026-05-14, PR A). Constants live in `app/lib/core/squat_form_audit_defaults.dart` and `app/lib/core/curl_form_audit_defaults.dart`. Replaces the pre-2026-05-14 `FormThresholds.forSensitivity` / `SquatFormThresholds.forSensitivity` factories which produced a safety inversion (gentler tier → weaker warnings). **2026-05-15:** the dead-band layer (curl only) is user-tunable via `Form Tolerance Percent`; the audit thresholds themselves remain fixed. |
| **ROM Gate** | A threshold defining the angular range that counts as a valid rep (peak, start, bottom, end, shallow, depth). Tier-dependent via `FeedbackSensitivity` through the post-pass on `RomThresholds.applySensitivity` (curl) / `SquatRomThresholdSet.applySensitivity` / `PushUpRomThresholdSet.applySensitivity`. Distinct from `Form Audit`, which is fixed regardless of tier. |
| **FormThresholds** | Pure value class in `core/form_thresholds.dart`. Bundles all 6 form-error threshold constants (`swingThreshold`, `torsoLeanThresholdDeg`, `backLeanThresholdDeg`, `shrugThreshold`, `driftThreshold`, `elbowRiseThreshold`) into a single injectable object. `FormThresholds.medium` is the canonical fixed instance — sourced from `CurlFormAuditDefaults` (which mirrors the `k*` constants) so existing behavior is unchanged. The `medium` name is preserved for source-compat with default-arg call sites in `RepCounter`, `CurlStrategy`, `CurlSideFormAnalyzer`; semantically it is "the fixed thresholds," not "the medium tier" — there is no high tier any more (Sensitivity vs Form Audit doctrine, 2026-05-14 PR A). Created once in `WorkoutViewModel.init()` and injected down through `RepCounter → CurlStrategy → CurlFormAnalyzer / CurlSideFormAnalyzer`. **2026-05-15:** gained a `formTolerancePercent` field and six `effectiveXDeadband` getters that linearly interpolate between the `kFormMinMovement*` baseline and the corresponding audit threshold per the `Form Tolerance Percent` contract. The audit-threshold fields are unchanged; only the dead-band layer is user-controllable. `FormThresholds.withTolerance(int)` factory clones `medium` with a clamped percent. |
| **Form Tolerance Percent** | User-controlled value in `[0, 100]` that scales the curl form-audit dead-band layer between the hard-coded baseline (`kFormMinMovement*`, equivalent to `0` = strictest) and the corresponding audit threshold (`100` = dead-band collapses onto the threshold, only clear faults trigger cues). Persisted via `preferences` table key `form_tolerance_percent`. Snapshot-on-construction in `WorkoutViewModel.init()` — mid-session Settings changes do NOT affect an in-flight workout. **Does NOT affect** rep counting, rep quality scoring, or post-session form-audit summaries — only the live cue-firing stream consumed by TTS and on-screen highlights. Default `0` (= `kDefaultFormTolerancePercent`) preserves the 2026-05-15 hard-coded behavior bit-for-bit for upgrading users. Doctrine compliance: scales the dead-band only, never the audit threshold — see `.agent_brain/SKILLS.md` "Sensitivity vs Form Audit" extension (2026-05-15). **Scope:** curl-only as of 2026-05-15; the squat / push-up dead-band layer is a planned follow-up. Once those land, the **same** persisted value drives all three exercises (one dial, no new UI). See `Coaching Strictness vs Form Tolerance` for the doctrinal separation from `FeedbackSensitivity`. |
| **Baseline Dead-Band** | The pre-2026-05-15 hard-coded floor for each curl audit cue, defined in `app/lib/core/constants.dart` as the `kFormMinMovement*` family (`kFormMinMovementSwingRatio = 0.08`, `kFormMinMovementLeanDeg = 3.0`, `kFormMinMovementShrugRatio = 0.06`, `kFormMinMovementDriftRatio = 0.08`, `kFormMinMovementRiseRatio = 0.08`). Represents the ML Kit + 1€-filter pose-noise floor below which a magnitude is treated as jitter regardless of user preference. The `Form Tolerance Percent` dial can never push the `Effective Dead-Band` below this baseline. |
| **Effective Dead-Band** | The runtime per-cue dead-band actually used by `CurlSideFormAnalyzer.evaluate`. Computed at `FormThresholds` construction time as `baseline + (alert_threshold − baseline) × percent / 100`. Always satisfies `baseline ≤ effective ≤ alert_threshold` thanks to the defensive clamp in `FormThresholds._effectiveDeadband` (returns the baseline if `baseline ≥ threshold`, so a future bad retune degenerates to a no-op for that cue rather than crashing). Exposed via six getters: `effectiveSwingDeadband`, `effectiveLeanDeadband`, `effectiveBackLeanDeadband`, `effectiveShrugDeadband`, `effectiveDriftDeadband`, `effectiveRiseDeadband`. |
| **Coaching Strictness vs Form Tolerance** | Two **independent dials** for two **independent threshold systems**, separated by the 2026-05-14 "Sensitivity vs Form Audit" doctrine and the 2026-05-15 dead-band extension. Coaching strictness (`FeedbackSensitivity`, enum Medium/High) controls **ROM gates** — what counts as a rep — and applies uniformly across all three resolver tiers (calibrated, auto-cal, cold-start) via `RomThresholds.applySensitivity` for curl and analogous post-passes for squat / push-up. Form tolerance (`formTolerancePercent`, int 0..100) controls **the form-audit dead-band layer** — when the audit *talks to the user* about how a rep looked — and currently applies to curl only. The two dials never share code paths: the `applySensitivity` post-pass never reads `formTolerancePercent`, and the `effectiveXDeadband` getters never read `FeedbackSensitivity`. Affect matrix: ROM gates / rep counts / rep quality scoring are governed by Coaching strictness only; the live form-cue firing stream is governed by Form tolerance only; the post-session `FormAuditor` audit summary is tolerance-invariant by design (`form_auditor.dart` always uses `FormThresholds.medium`). Verified by `app/test/core/form_audit_independence_test.dart` (Coaching strictness doesn't reach form audit) and `app/test/engine/curl/curl_side_form_analyzer_tolerance_test.dart` quality-score invariance assertion (Form tolerance doesn't reach rep quality). |
| **frontStrict / frontDefault** | Two named `CurlRomThresholdSet` constants in `CurlRomDefaults` (High/Medium sensitivity tiers for the front-view curl). Derived from the 2026-04-26 diagnostic session plus ±ROM deltas (High: start+5°, peak−10°). The `Permissive` tier was removed when the project unified sensitivity to High/Medium only (2026-05-13). |
| **SessionSummaryViewModel** | `view_models/session_summary_view_model.dart`. Immutable value class that translates the `SummaryScreen` widget's flat constructor inputs into normalized slot data (qualityPct, grade, heroSubtitle, variantLabels, formIssues, insights, formAudit, …) for the unified summary builder. One private factory per `ExerciseType` (`_fromCurl`, `_fromSquat`, `_fromPushUp`); `fromSummary` dispatches. Not a `ChangeNotifier` — the summary is a terminal page with no live updates. |
| **FtAccentCard** | `core/theme.dart`. **Strip removed app-wide 2026-05-13** — the "AI surface" left-edge cyan strip is gone. Now renders as a plain rounded surface with a uniform `Border.all`. The `accentColor` constructor parameter is retained for source-compat with three existing call-sites (`home_screen.dart:492, 1968, 2035`) but is no longer painted. New call-sites should prefer `Container(decoration: ftCardDecoration(...))`. **Why kept:** the paint-safety lesson (Flutter forbids `borderRadius` on a non-uniform `Border`) is still true — `SummaryHero`'s former paint pattern would have hit it; the workaround just isn't needed anymore because there's no strip to paint. |
| **_applyRomSensitivity** | **Renamed `_applyLooseness` (2026-05-14)** with the uniform-sensitivity contract. Private static helper on `RomThresholds`. Applies looseness deltas to a High-anchored threshold set and re-derives `peakExitAngle = peak + kCurlPeakExitGap`. Two floor modes: strict (`end > peakExit + gap`) for bucket-derived and Tier-3 anchors; soft (`end > peakExit`) for the Tier-1 telemetry path where curated tuples ship with small end-to-peakExit gaps. |
| **Sensitivity Anchor** | The **High-sensitivity threshold tuple** returned by every resolver tier (calibrated, auto-cal, telemetry, cold-start) under the uniform-sensitivity contract (2026-05-14). Each per-exercise `*_rom_defaults.dart` exposes its anchor via `forSensitivity` / `anchor` / `forVariant`. The anchor is the canonical reference; non-High levels are derived from it via the sensitivity post-pass. Replaces the pre-2026-05-14 model where Medium was the anchor and High was a delta. |
| **Looseness Delta** | Field-by-field offsets applied to a Sensitivity Anchor to produce non-High threshold sets. Defined in three places — `RomThresholds._tier3MediumLooseness` `(-5, +10, 0)`, `RomThresholds._telemetryMediumLooseness` `(-3, +8, +8)`, and `RomThresholds._bucketMediumLooseness` `(-5, +10, 0)` for curl; `SquatRomThresholdSet._mediumLooseness` `(-5, +2, -3)` for squat; `PushUpRomThresholdSet._mediumLooseness` `(-5, +5, -3, +5)` for push-up. Per-tier separation is required because each tier's strict/loose gap is independent. Always invariant-safe via FSM completability floors re-asserted after delta application. |
| **Sensitivity Post-Pass** | The single chokepoint where `.applySensitivity(highAnchored, userSensitivity)` runs, just before the resolver returns the FSM threshold tuple. Implemented as an instance method on `RomThresholds` (curl), `SquatRomThresholdSet`, and `PushUpRomThresholdSet`. Idempotent on High. The only place ROM gates read the user's sensitivity selection. **Form audit no longer goes through this chokepoint** — per the Sensitivity vs Form Audit doctrine (2026-05-14, PR A), form-error thresholds are fixed (`FormThresholds.medium` / `SquatFormThresholds.defaults`). Bypassed by the diagnostic path via `RomThresholds.globalUnmodified` to keep the offline tuning workflow circular-free. |
| **RomThresholds.globalUnmodified** | Factory introduced 2026-05-14 for the curl diagnostic short-circuit (`diagnosticDisableAutoCalibration`). Returns the Tier-3 Medium-baseline tuple (`kCurlStartAngle`/`kCurlPeakAngle`/`kCurlPeakExitAngle`/`kCurlEndAngle`) with no sensitivity post-pass. The diagnostic workflow needs a stable baseline against the constants the offline Python derivation script was calibrated with; applying sensitivity there would make measurements circular. |
| **Anchor (threshold derivation)** | The statistical point estimate used as the base value for a sensitivity tier in the Python derivation scripts (`tools/dataset_analysis/scripts/anchors.py`). Two named anchors cover every gate: `median_anchor` (bootstrapped HD P50) for ROM gates — curl peak, curl start, push-up bottom, push-up start, push-up shallow, squat depth; `p95_anchor` (HD P95) for fault upper bounds — squat lean, knee shift, heel lift. Distinct from `Sensitivity Anchor`, which refers to the High-tier Dart threshold tuple inside the FSM resolver. See `.agent_brain/SKILLS.md` "Threshold Derivation Pipeline" doctrine (2026-05-14 PR B). |
| **Tier Tolerance** | The per-tier additive constant applied on top of an `Anchor (threshold derivation)` to produce the final FSM gate at the script level. Stored in per-exercise `*_SENSITIVITIES` dicts (`SENSITIVITIES` for curl, `PUSHUP_SENSITIVITIES` for push-up; squat form audit uses `SQUAT_FORM_AUDIT_CONFIG`, a single non-tiered config because form audit is tier-independent by doctrine). ROM gates only — form audit uses one fixed tolerance per metric. Iterated via `scripts.sensitivity.TIERS = ("high", "medium")` so adding a tier means touching one Python module plus the Dart `FeedbackSensitivity` enum in lock-step. |
| **_FormAuditDualStat / _FormAuditStat** | Private widgets in `summary_screen.dart` (2026-05-13). Twin big-stats header on the Form Audit card showing Form Accuracy and Clean Reps side-by-side with matching typography (48 px digit + 22 px `%` + 10 px caption). Each stat picks its own tier color from its own value via `_SummaryScreenState._tierColor(double v, FiTrackColors ft)` — ≥0.80 accent → ≥0.50 cyan → red. Replaces the prior single-hero "78% / Form Accuracy 86%" layout where Clean Reps read as the "real" score and Form Accuracy as a footnote. Reps-clean / criteria count moves below as a small caption. |
| **_tierColor** | Tier-color helper on `_SummaryScreenState` (`summary_screen.dart`, 2026-05-13). Maps a 0..1 score to the form-audit pass-rate ramp (`≥0.80 → accent`, `≥0.50 → cyan`, else red). Used by `_FormAuditDualStat` so each twin stat colors independently of the other (e.g., a session can show green Form Accuracy + red Clean Reps when the user moved well overall but had several flagged reps). |
| **_accuracyByRepExpanded / _expandedRepIndex** | State fields on `_SummaryScreenState` (`summary_screen.dart`, 2026-05-13). The first toggles the "Accuracy by Rep" section collapse (collapsed by default to keep the Form Audit card opening light); the second tracks which single rep row inside the section is currently expanded (`int?`, null = no row expanded). Single-expand behavior keeps the card compact on 20-rep sessions — tapping rep N collapses any other open rep. |
| **_RepAccuracyTile / _RepDetailRow** | Private widgets in `summary_screen.dart` (2026-05-13). `_RepAccuracyTile` is the row widget for the "Accuracy by Rep" list — bar + percentage + chevron, tap-to-expand; expanded state highlights the row with a subtle surface tint and reveals an indented `_RepDetailRow` panel below the bar. `_RepDetailRow` is a single label/value pair (`SizedBox(width: 96) + Text` with tabular figures). |
| **_buildRepDetails** | Per-rep detail panel builder on `_SummaryScreenState` (`summary_screen.dart`, 2026-05-13). Pulls from five independent data sources, emitting a row only when the corresponding field is non-null: (1) `curlRepRecords[i]` → ROM (`maxAngle → minAngle (Δ romDegrees)°`), arm side, rejected-outlier status. (2) `widget.repConcentricMs[i]` → tempo (`X.X s concentric`). (3) `widget.repDepthPercents[i]` → depth as % of reference. (4) `widget.bicepsSideRepMetrics[i]` → curl-side peaks (lean, shoulder arc, elbow drift, back lean) when populated. (5) `widget.squatRepMetrics[i]` → squat peaks (trunk lean, knee shift, heel lift) — each field null-guarded since `SquatRepMetrics` is `double?`-everywhere. Front-curl reps show ~4 rows, side-curl up to 8, push-up just ROM+tempo. **Not surfaced:** per-rep `FormError` flags — `errorsTriggered` is session-level, would require a DTO/engine plumbing change. |
| **_buildSideViewSection** | Helper on `_SummaryScreenState` (`summary_screen.dart`, 2026-05-13). Returns the bare column of side-view biceps form averages (Trunk lean, Shoulder arc, Elbow drift, Back lean, Shoulder shrug, Elbow rise) **without card chrome** — the parent `_buildDetailsCard` provides the rounded surface + padding. Replaces the standalone `_buildBicepsSideRatioStrip` (deleted same date). Caller guards on `widget.bicepsSideRepMetrics.isNotEmpty`. **Details-card guard widening:** the parent sliver's condition was extended from `(curlRepRecords.isNotEmpty || curlBucketSummaries.isNotEmpty)` to also admit `widget.bicepsSideRepMetrics.isNotEmpty`, so a side-view-only session still renders the Details card with just the merged sub-section. |
| **_PushUpProfileSection** | Private widget in `settings_screen.dart` (2026-05-13). Push-up's calibration card, mirroring `_SquatProfileSection`'s shape (single bucket, icon + title + status pill + body line "Top X° · Bottom Y° · ROM Z°" or "Not calibrated…"). Renders under its own `_subSectionHeader('Push-up')` in the Settings → Calibration section, parallel to "Biceps curl" and "Squat". **Why it exists:** before 2026-05-13, push-up was rendered inside `_ProfileSection` alongside the Biceps Curl Profile, separated only by a `Divider` inside one shared `Card`. The "Biceps curl" subheading therefore lied — it actually covered both. Split into its own widget so the visual subheading honestly describes its contents. |
| **_confirmResetPushUp** | Dialog handler on `_SettingsScreenState` (`settings_screen.dart`, 2026-05-13). Mirrors `_confirmResetSquat`: opens an `AlertDialog` ("Reset Push-Up Profile?"), calls `_repository.resetPushUp()` only on confirm, then `_reload()`. **Existence rationale:** pre-2026-05-13, `_confirmReset` ("Reset curl profile") called both `_repository.resetCurl()` AND `_repository.resetPushUp()` — the button label promised curl-only but the action wiped both. The stray `resetPushUp()` call was removed from `_confirmReset` and given its own dedicated handler so push-up's destructive action lives on its own button. |

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
- **`SessionSummary.qualitySeries`** — `List<double>` of per-rep `quality` scores (0..1) in `rep_index` ASC order, attached by `SqliteSessionRepository.listSessions` via a single batched `SELECT session_id, quality FROM reps WHERE session_id IN (?, …) AND quality IS NOT NULL ORDER BY session_id, rep_index ASC`. Drives the History list's per-row sparkline so each card's line reflects the actual form trajectory of that session. NULL-quality rows are excluded server-side, so `length ≤ totalReps`. Empty for sessions with no per-rep quality (pre-WP6 rows or zero-rep sessions). Read by `home_screen.dart`'s `_RowSparkline`; not yet read by the legacy dark-themed `widgets/session_card.dart` row (only the home-shell History tab consumes it as of 2026-05-13).
- **`_RowSparkline`** — `home_screen.dart`'s per-session sparkline widget. Renders `SessionSummary.qualitySeries` with **per-session auto-rescaling** (no `minOverride`/`maxOverride` passed) so each session uses the full vertical band to show its within-session shape — a flat-good session at 0.86–0.92 renders a legible trajectory rather than a near-flat line at the top. Tradeoff: cross-session comparison by vertical position is no longer meaningful (each card is shape-only). For 0/1-point series (legacy rows, no-quality sessions) falls back to a faint flat baseline so the row layout stays stable. **History:** shipped 2026-05-13 with fixed 0..1 scale; same-day flip to auto-rescale after on-device review showed the fixed scale flattened most sessions at the small 28 px height. The `FtSparkline.minOverride/maxOverride` plumbing is retained for larger callers where vertical position is the primary read.
- **`FtSparkline.minOverride / maxOverride`** — Optional fixed-scale parameters on `core/theme.dart`'s `FtSparkline`. When set, the painter uses them instead of `data.reduce(min/max)` and clamps each sample to `[0, 1]` of the fixed range before plotting. Lets quality-domain sparklines render on a stable 0..1 axis (so micro-variations don't look dramatic); leaving them null preserves the original auto-scaling behavior for other call-sites.
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

## 13c. Form Audit (2026-05-13)

Post-session retrospective grading, **default-on for every exercise**. **Replaces the deleted DTW Reference Rep Scoring system** — see §14 for the retired terms. The user-visible card on the summary screen is titled simply "Form audit".

| Term | Meaning |
|---|---|
| **Form Audit** (concept) | The post-session retrospective grade. Re-applies the form-error and ROM thresholds to each rep's already-persisted maxes — but via **Path B-permissive tier priority (2026-05-13)** rather than a fixed strict bar: each rep grades against the most personalized **ROM** bar available (calibrated profile → auto-cal snapshot → cold-start at session sensitivity). Form-error thresholds are FIXED (Sensitivity vs Form Audit doctrine, 2026-05-14 PR A) — the user's session sensitivity drives ROM tier resolution only; form audit always runs at the biomechanical bar. Always on, no toggle. Matches the industry standard (Strava / Whoop / Future) of grading ROM against the user's own baseline while keeping form coaching at a fixed safety threshold. |
| **FormAuditor** | Pure-Dart stateless class in `engine/form_auditor.dart`. Three entry points dispatch by exercise: `auditCurl(...)`, `auditSquat(...)`, `auditPushUp(...)`. Each takes the relevant per-rep DTOs + personalization context (profile / auto-cal snapshot / sensitivity) from the live `WorkoutCompletedEvent`, walks the tier-priority chain per rep, returns a `FormAudit`. No I/O, no analyzer replay — pure aggregation over already-persisted data. |
| **Tier-priority chain (audit)** | Per-rep ROM bar resolution: (1) `curlProfile.bucketFor(side, view)` with ≥ `kCalibrationMinReps` samples → Tier 1; (2) session-end `autoCalSnapshot` → Tier 2; (3) `RomThresholds.global(view, sensitivity)` → Tier 3 (sensitivity-modified). Mirrors the live FSM's resolver in `WorkoutViewModel._resolveThresholds`. Push-up has only Tier 1 (`PushUpRomProfile.thresholds`) and Tier 3 (`PushUpRomDefaults.defaults`) since push-up has no in-session auto-calibrator. |
| **Path B-permissive** | The audit grading philosophy adopted 2026-05-13: personalize the bar to whatever the live FSM was using, don't layer strictness on top. The alternative ("Path B-strict") was rejected because it violated the project invariant in `rom_thresholds.dart` that personalized thresholds are never modified by sensitivity. The user's session sensitivity dial is the ONE input that adjusts strictness; the audit honors that choice rather than overriding it. |
| **FormAudit** | Immutable aggregate value class: `repsClean` / `repsEvaluated` / `repsTotal` (int), `perCriterion: List<CriterionResult>`, `oneShotFlags: Set<String>`, `applicable: bool`, `notApplicableReason: String?`, computed getter `passRate`. `applicable == false` → no per-rep metrics survived (pre-schema reconstructed session); card shows footnote and skips the tally. |
| **CriterionResult** | Per-criterion tally: `{ name, evaluated, fired }`. `passed` is `evaluated - fired`. Criteria with zero evaluable reps are dropped from the audit before display (keeps the card clean for sessions where the criterion doesn't apply at all). |
| **Form Audit card** | `SummaryScreen._buildFormAuditCard` — replaces the deleted Form Match Card at slot `[3.5]`. Dispatches by `ExerciseType`. Layout: pass-percentage hero number, "N of M reps clean" subhead, per-criterion rows (green when fired==0), one-shot flag chips (Fatigue / Asymmetry) below. Color band: ≥80% green, ≥50% cyan, else red. |
| **Audit criteria — curl front** | Peak depth, Start extension, Swing, Depth swing. Inputs: `CurlRepRecord.{minAngle, maxAngle}` + `BicepsFrontRepMetrics.{swingRatio, depthSwingRatio}`. |
| **Audit criteria — curl side** | Peak depth, Start extension, Trunk lean, Back lean, Elbow drift, Shoulder drift, Shrug, Elbow rise. Inputs: `CurlRepRecord.{minAngle, maxAngle}` + `BicepsSideRepMetrics.{leanDeg, backLeanDeg, elbowDriftRatio, shoulderDriftRatio, shrugRatio, elbowRiseRatio}`. |
| **Audit criteria — squat** | Depth, Forward lean, Knee shift, Heel lift. Inputs: `SquatRepMetrics.{quality, leanDeg, kneeShiftRatio, heelLiftRatio}`. Depth uses `quality < 0.85` as a proxy because per-rep min-knee-angle isn't separately persisted. Lean threshold gates on `SquatFormThresholds.high.leanWarnFor(variant, longFemur)`. |
| **Audit criteria — push-up** | Depth, Start extension only. Per-rep body-line / sag / pike / shallow metrics aren't persisted today (no `PushUpRepMetrics` DTO exists yet); coverage will expand on the next schema bump. Calibration overrides intentionally NOT consulted so the audit compares across sessions and users on a fixed bar. |
| **One-shot flags** | Session-level detections (`fatigueDetected`, `asymmetryDetected` — curl-only) reported as separate chips below the per-criterion list. Not tallied per-rep — they fire once and latch. |
| **BicepsFrontRepMetrics** | Per-rep DTO in `core/types.dart` (schema v7, 2026-05-13). Fields: `repIndex`, `swingRatio`, `depthSwingRatio`. Populated only for `bicepsCurlFront` sessions. Mirrors the existing `BicepsSideRepMetrics`. |

---

## 13d. User Profile & Production-Readiness Vocabulary (2026-05-13)

These terms cover the local-only user profile, the dashboard aggregates,
and the production-roadmap surfaces shipped in the
`we-will-refine-the-eager-fountain` PR.

| Term | Definition |
|---|---|
| **`UserProfile`** | Immutable value type in `app/lib/models/user_profile.dart`. Captures display name, optional demographics (age/gender/height/weight), fitness experience + primary goal, and an embedded `List<UserGoal>`. Persisted as the single row in the `user_profile` SQLite table (schema v8). |
| **`UserGoal`** | Free-form goal item shown in the Profile tab's "Active Goals" list. Fields: `id` (creation timestamp), `title`, optional `detail`, optional `targetDate`, `completed` boolean. JSON-encoded into `user_profile.goals_json`. |
| **`UserProfileRepository`** | Abstract repo + `SqliteUserProfileRepository` impl in `app/lib/services/db/user_profile_repository.dart`. Single-row semantics enforced by the DDL `CHECK (id = 1)`. Returns `null` from `load()` when the user has not yet completed Edit Profile — UI uses null as the "anonymous" sentinel. |
| **`Units`** | Enum (`metric` / `imperial`) controlling **display + input** units only. Storage on disk is always metric (cm, kg). Conversion happens at the UI boundary in `app/lib/utils/units.dart`. Toggling units never mutates any saved height/weight. |
| **`Gender`** | Enum (`male` / `female` / `preferNotToSay`) on `UserProfile`. Self-reported. Used for future calorie/load estimates; never gates any feature. |
| **`ExperienceLevel`** | Enum (`beginner` / `intermediate` / `advanced`) on `UserProfile`. Reserved for future cold-start sensitivity defaults. The existing `FeedbackSensitivity` preference still wins when explicitly set. |
| **`FitnessGoal`** | Enum (`buildMuscle` / `loseFat` / `improveForm` / `generalFitness`) on `UserProfile`. Surfaces in the Profile-tab hero subtitle. |
| **Strain (proxy)** | Sum of `(reps × duration_minutes)` across the last 7 days, scaled so 50 rep-minutes ≈ 1 strain unit, then clamped to a 0..21 display range. Defined in `dashboard_aggregates.dart::computeStrain`. **Not** the Whoop metric — we have no HRV/sleep sensors. |
| **Recovery (proxy)** | `min(daysSinceLastFatigueFlaggedSession / 7, 1.0)`. Defaults to `1.0` when no fatigue-flagged session exists ever. Defined in `dashboard_aggregates.dart::computeRecovery`. |
| **Output (proxy)** | Mean `averageQuality` across last-7-day sessions. Already 0..1; UI multiplies by 100 for percentage display. Defined in `dashboard_aggregates.dart::computeOutput`. |
| **`DashboardMetrics`** | Result bundle returned by `computeDashboardMetrics()` — single-pass computation of strain, recovery, output, weekly bars, total sessions, total hours, distinct exercise count (proxy "PRs"), and weekly rep count. Cached on `HomeViewModel.metrics`. |
| **Weekly Volume bars** | Seven `int` rep counts, one per ISO weekday (index 0 = Mon, 6 = Sun) for the **current** Monday-anchored week. Empty bars render a 4-pixel "stub" so the weekday baseline reads visually with no data. |
| **`EditProfileScreen`** | Form screen in `app/lib/screens/edit_profile_screen.dart` reachable from the Profile tab. Sections: Identity, Demographics, Fitness, Preferences (Units / TTS / Haptics). Required field: display name only. Validates: age 10–120, height 80–250 cm, weight 20–300 kg. |
| **`PRODUCTION_ROADMAP.md`** | Project-root document tracking deferred production work. Phase 1 (this PR) ships local profile + placeholders. Phases 2–7 cover onboarding, backend choice, auth, cloud sync, photo avatar, GDPR-style controls. Live document — update phase status as work begins. |

---

## 13e. Squat Pipeline Overhaul Part 1 — Data Foundation (2026-05-13)

These terms cover the pure-data foundation introduced by Part 1 of the squat
pipeline overhaul. All constants and types in this section are **defined and
shipped** by Part 1; some are consumed by later parts (annotated below).

| Term | Definition |
|---|---|
| **`kSquatStartAngleHigh`** | Const `165.0`. High-sensitivity IDLE → DESCENDING gate. Source: deep-research biomechanical spec (2026-05-13). Looser than Medium (`160°`) so a higher knee extension at top is required before the FSM enters DESCENDING. Consumed by `SquatRomThresholdSet.forSensitivity(high)`. |
| **`kSquatBottomAngleHigh`** | Const `47.1` (telemetry-derived 2026-05-15; the older `88.0` literal predates that retune). Lives in the High-anchored `SquatRomThresholdSet` tuple. **Defined but NOT consumed by the FSM at transition time** — the live depth gate is `_effectiveBottomAngle` in `SquatStrategy`, sourced from `kSquatBottomAngle` (80° as of 2026-05-16, tightened from 90°) or `kLongFemurBottomAngle` (100°, long-femur path). The resolved tuple's `bottomAngle` is logged as `bottom_tuple=` on `squat.thresholds_resolved` (parser-continuity only — NOT the enforced gate); the **actually-enforced** per-rep gate is logged as `effective_bottom=` on the `squat.rep` line, which is the field the offline threshold-derivation workflow must use. Wiring the tuple `bottomAngle` into the FSM (or formally deleting the dead field) is a tracked future PR. |
| **`kSquatEndAngleHigh`** | Const `163.0`. High-sensitivity ASCENDING → IDLE commit gate. Source: same spec. Stricter than Medium (`160°`) so a fuller extension is required at the top of the rep. Consumed by `SquatRomThresholdSet.forSensitivity(high)`. |
| **`kSquatCalibrationMinReps`** | Const `3`. Minimum reps for squat personal calibration to commit. Mirrors `kCalibrationMinReps` (curl). **Defined; consumed by future squat-calibration PRs.** Lives separately from the curl constant so a per-exercise dial can diverge values without a refactor. |
| **`kSquatMinViableRomDegrees`** | Const `40.0`. Minimum ROM excursion (degrees) for a squat rep to qualify as a valid calibration sample. **CANONICAL NAME** — referenced by Parts 5, 6, 8 of the overhaul. Looser than the curl floor (`25°`) because squat reps with shallow knee flexion still carry calibration value via the long-femur path. |
| **`kSquatProfileBottomMargin`** | Const `5.0`. Margin (degrees) added to `observedMinKneeAngle` when deriving the BOTTOM gate from a calibrated profile. Mirrors `kPushUpProfileBottomMargin` / the curl profile's peak-tolerance pattern — the gate sits a touch *above* the observed deepest angle so a noisy rep doesn't fail the user's own bar. **Defined; consumed by future squat-calibration PRs.** |
| **`kSquatProfileStartMargin`** | Const `10.0`. Margin (degrees) subtracted from `observedMaxKneeAngle` for the START gate. Wider than the END margin so the FSM enters DESCENDING decisively before the user is committed to the rep. **Defined; consumed by future squat-calibration PRs.** |
| **`kSquatProfileEndMargin`** | Const `5.0`. Margin (degrees) subtracted from `observedMaxKneeAngle` for the END gate. Tighter than the START margin so the rep doesn't commit prematurely — mirrors curl's `start > end` FSM invariant. **Defined; consumed by future squat-calibration PRs.** |
| **`SquatRomThresholdSet.forSensitivity(FeedbackSensitivity)`** | Factory introduced in Part 1. Exhaustive switch over `FeedbackSensitivity` returning the High tuple (`165 / 88 / 163`) for `high` and `SquatRomDefaults.defaults` (`160 / 90 / 160`) for `medium`. Adding a future enum case (e.g. `low`) becomes a compile-time error here — the switch is the enforcement point. Consumed by `SquatStrategy(romThresholds: ...)`. |
| **`SquatRomDefaults.forVariantAndSensitivity(variant, sensitivity)`** | Lookup added in Part 1. Variant-agnostic today — delegates to `SquatRomThresholdSet.forSensitivity(sensitivity)`. Signature kept symmetric with `forVariant` so a future per-variant ROM split (e.g. wider BOTTOM for HBBS) lands as a single method body change with no call-site churn. |
| **`SquatRepMetrics.minKneeAngle`** | Nullable `double` field added in Part 1. Persisted in `reps.squat_min_knee_angle` (schema v9). The deepest knee angle reached during a rep — feeds the future personal-calibration pipeline. NULL on reconstructed pre-v9 sessions and on reps the analyzer couldn't measure throughout the descent. |
| **`SquatRepMetrics.maxKneeAngle`** | Nullable `double` field added in Part 1. Persisted in `reps.squat_max_knee_angle` (schema v9). The maximum knee-angle observation during a rep (typically the top-of-rep extension). Same NULL semantics as `minKneeAngle`. |
| **Schema v9** | Bumps `kDbSchemaVersion` to 9. Pure CREATE-style additive migration: `ALTER TABLE reps ADD COLUMN squat_min_knee_angle REAL` + `ALTER TABLE reps ADD COLUMN squat_max_knee_angle REAL`. Mirrored ALTERs added to `onCreate` so a fresh install gets the identical schema to a migrated DB. Populated only on squat rows; NULL on curl, push-up, and pre-v9 rows. **Plan-to-build deviation note:** the plan referenced "v8" — a parallel agent shipped v8 for `user_profile` during the same session, so the squat columns landed as v9 instead. Additive contract preserved through both steps. |

---

## 13f. Squat Pipeline Overhaul Part 2 — Engine Calibration Stack (2026-05-13)

Concepts and types introduced by Part 2, the engine-layer parity PR. All entries are pure-Dart; no UI surface is wired in Part 2 (calibration overlay is gated until Part 3).

### Concepts

| Term | Definition |
|---|---|
| **Anatomical long-femur classification** | Distinct from the legacy rep-history long-femur heuristic. The classifier examines the user's femur/torso length ratio over a sliding window of high-confidence frames and locks a median once enough samples accumulate. When the locked ratio exceeds `kLongFemurRatioThreshold` (0.60), the squat BOTTOM gate relaxes to `kLongFemurBottomAngle` (100°) **from rep 1**, instead of requiring 3 consecutive shallow reps. Falls back to the rep-history heuristic when the classifier doesn't lock (low-confidence framing) or locks below threshold. Per-session anatomy is not expected to change, so the classifier locks once and is no-op for the rest of the session. |
| **Tier-priority squat threshold resolution** | Three-tier chain in `WorkoutViewModel._resolveSquatThresholds(repIndexInSet)`, called once per rep at IDLE→DESCENDING and locked into the strategy's `_activeThresholds` for the rest of the rep. **Tier 1** — personal `SquatRomProfile.bucket` if `isCalibrated == true` (≥ `kSquatCalibrationMinReps` samples). **Tier 2** — `SquatAutoCalibrator.currentThresholds` (≥ 2 in-session reps with viable ROM). **Tier 3** — `SquatRomThresholdSet.forSensitivity(activeFeedbackSensitivity)`. Each tier resolution logs `squat.thresholds_resolved tier={1,2,3}` for telemetry. Mirrors `WorkoutViewModel._resolveThresholds` for curl. |
| **Threshold-lock invariant (squat)** | The resolver runs at IDLE→DESCENDING; the result is stored in `SquatStrategy._activeThresholds` and consumed by every subsequent DESCENDING / BOTTOM / ASCENDING transition for the rest of the rep. Tier 1/2/3 cannot fight over thresholds mid-rep. Mirrors curl's `_activeThresholds` invariant. |

### Constants

| Term | Definition |
|---|---|
| **`kLongFemurRatioThreshold`** | Const `0.60`. Femur/torso ratio above which the anatomical classifier classifies the user as long-femur and relaxes the BOTTOM gate to `kLongFemurBottomAngle` (100°). Source: deep-research biomechanical spec (2026-05-13). |
| **`kFemurTorsoMinSamples`** | Const `5`. Minimum high-confidence frames the `_FemurTorsoClassifier` must observe before it locks a median. Filters ML Kit's first-frame jitter. |
| **`kFemurTorsoWindowSize`** | Const `15`. Sliding-window cap for the classifier's pre-lock median calculation. Bounds memory and pre-lock reaction time. Once locked, the classifier is no-op so the window size does not apply post-lock. |

### Types & APIs

| Term | Definition |
|---|---|
| **`_FemurTorsoClassifier`** | Engine-internal private class inside `engine/squat/squat_strategy.dart`. Collects per-frame `femur / torso` ratios (femur = hip↔knee distance, torso = shoulder↔hip distance) on the higher-confidence side of the body. Once ≥ `kFemurTorsoMinSamples` samples accumulate, takes the median over the window, locks the result, and ignores further input. Supports `seedFromPersisted(double)` so a returning user with a stored ratio gets immediate classification without re-warmup. Confidence floor: `kSetupCurlMinConfidence` (0.65) — the same floor curl uses for setup-quality decisions. |
| **`SquatRomBucket`** | Per-user squat ROM bucket living in `engine/squat/squat_rom_profile.dart`. Owns `observedMinKneeAngle` (deepest flexion), `observedMaxKneeAngle` (most extended), `sampleCount`, optional `femurTorsoRatio`, FIFO sample buffers, and shrink-confirm counters. `applyRep(min, max)` returns a `RepApplyResult` and mirrors `engine/curl/curl_rom_profile.RomBucket.applyRep` 1:1 — same expand-fast α=0.4 / shrink-slow α=0.1 / 3-rep shrink-confirm / MAD outlier rejection. MAD is suppressed while a shrink trend is already pending (mirrors curl's `_consecutiveShrinkCandidatesMin == 0` gate). Single bucket per user — no `(side, view)` axis like curl. |
| **`SquatRomProfile`** | Top-level squat ROM profile in `engine/squat/squat_rom_profile.dart`. Schema version 1. Owns `userId`, single nullable `SquatRomBucket bucket`, `createdAt`, `lastUsedAt`. `isCalibrated` returns true iff the bucket exists and has accumulated ≥ `kSquatCalibrationMinReps` samples. **The bucket is exposed as a direct field — there is no `bucketFor()` facade**, because squat has no key axis to look up against (per simplicity review). |
| **`SquatRomBucketLike`** | Abstract structural interface in `core/rom_thresholds.dart`. Parallels `RomBucketLike` for curl but uses squat-specific field names (`observedMinKneeAngle` / `observedMaxKneeAngle`). Implemented by both `SquatRomBucket` (the persistent bucket) and `_SquatAutoBucket` (the auto-calibrator's in-flight bucket). Lives in `core/` so consumers in `view_models/` and `engine/` can both reach it without violating layer-boundary rules. |
| **`SquatAutoCalibrator`** | Transient in-set ROM estimator in `engine/squat/squat_auto_calibrator.dart`. Documented as a **verbatim mirror** of `CurlAutoCalibrator` with squat-typed return values. `recordRepExtremes(min, max)` filters each dimension independently through MAD outlier rejection and updates the per-dimension running average. `currentThresholds` returns a `SquatRomThresholdSet` once `repCount >= 2` AND `(maxAvg − minAvg) >= kSquatMinViableRomDegrees` (40°), else `null`. Reset on set rollover. **Future refactor opportunity acknowledged but deferred**: a generic `RomAutoCalibrator<T>` could unify curl + squat; for now the two implementations mirror each other and both must be kept in sync. |
| **`_SquatAutoBucket`** | File-private adapter in `squat_auto_calibrator.dart` that implements `SquatRomBucketLike` over the auto-calibrator's running averages. Used to expose the auto-cal's current averages as a bucket-shaped value via `SquatAutoCalibrator.currentBucket`. Not a persistence shape. |
| **`SquatRomThresholdsProvider`** | Typedef in `engine/squat/squat_strategy.dart` — `SquatRomThresholdSet Function(int repIndexInSet)`. Synchronous; the FSM hot path cannot await I/O. Implemented by `WorkoutViewModel._resolveSquatThresholds`. Called once per rep at IDLE→DESCENDING. |
| **`SquatLongFemurDetectedCallback`** | Typedef in `engine/squat/squat_strategy.dart` — `void Function(double medianRatio)`. Fires once per session when the anatomical classifier locks AND the ratio clears `kLongFemurRatioThreshold`. The host (`WorkoutViewModel`) wires telemetry + persistence here so the engine stays I/O-free. |
| **`SquatRepExtremesCallback`** | Typedef in `engine/squat/squat_strategy.dart` — `void Function({required int repIndex, required double minKneeAngle, required double maxKneeAngle})`. Fires after every committed rep. `RepCounter` buffers the strategy's emissions into private fields and drains them into the unified `SquatRepCommitCallback` so the host receives a single combined callback per rep. |
| **`SquatRepCommitCallback`** (extended in Part 2) | The existing typedef in `engine/rep_counter.dart` gained two required fields: `minKneeAngle` and `maxKneeAngle` (both `double?`). Production caller is `WorkoutViewModel._handleSquatRepCommit`, which feeds the extremes to `_squatAutoCalibrator.recordRepExtremes` AND applies them to the persistent bucket (lazy-create on first calibrated rep). |
| **`RepApplyResult`** (squat enum) | Enum in `engine/squat/squat_rom_profile.dart` — same shape and semantics as curl's `RepApplyResult` (`initialized`, `applied`, `shrinkPending`, `rejectedOutlier`). Imported under the `as squat_profile` prefix in `view_models/workout_view_model.dart` to disambiguate from curl's identically-named enum. Two-enum split is documented and intentional; a future unification is acknowledged but deferred. |

### Telemetry events

| Term | Definition |
|---|---|
| **`squat.thresholds_resolved`** | Logged once per rep at IDLE→DESCENDING. Body format: `tier={1,2,3} source=<calibrated/autoCalibrated/global> start=<deg> bottom=<deg> end=<deg>` plus tier-specific fields (`samples=N` for Tier 1, `reps=N` for Tier 2, `sensitivity=<name>` for Tier 3). |
| **`squat.anatomical_long_femur`** | Logged once per session when `_FemurTorsoClassifier` locks above threshold. Body format: `median_ratio=<float> threshold=<float>`. The host stamps the median back into the profile bucket's `femurTorsoRatio` field for cross-session seeding. |
| **`squat_profile.save_failed`** | Logged on a fire-and-forget persistence failure when `_flushSquatProfileIfDirty` catches an exception from `saveSquat`. Mirrors curl's `profile.save_failed`. |

---

## 13g. Squat Pipeline Overhaul Part 4 — Audit Upgrade + Telemetry Tooling (2026-05-13)

| Term | Definition |
|---|---|
| **`SquatSessionContext`** | Value class in `app/lib/view_models/workout_view_model.dart` that bundles the five squat-specific inputs the post-session Form Audit needs — `{variant, longFemurLifter, feedbackSensitivity, profile?, autoCalSnapshot?}`. Attached as a single nullable field on `WorkoutCompletedEvent` (`squatContext`) instead of growing five new flat fields. Null for non-squat sessions. The flat fields (`squatVariant`, `squatLongFemurLifter`, `squatRepMetrics`) are retained on the event for backward compatibility with the live summary screen rendering. |
| **Tier-priority squat audit grading** | The Part-4 contract for `FormAuditor.auditSquat`: each rep is graded against the most personalized ROM bar available — Tier 1 (`squatProfile.bucket` if `isCalibrated`) → Tier 2 (`autoCalSnapshot` if non-null) → Tier 3 (`SquatRomThresholdSet.forSensitivity(sensitivity)`). Replaces the pre-Part-4 always-Tier-3-at-High model. Form-error thresholds (lean / knee shift / heel lift) use `SquatFormThresholds.defaults` (fixed; see `Form Audit` entry and Sensitivity vs Form Audit doctrine in `.agent_brain/SKILLS.md`, 2026-05-14 PR A). Mirrors the **Path B-permissive** model documented for curl in `13c. Form Audit`. |
| **Squat telemetry derivation script** | `tools/dataset_analysis/scripts/derive_squat_thresholds_from_telemetry.py`. Consumes `min_knee` / `max_knee` from the `squat.rep` telemetry stream and emits a paste-ready Dart `SquatRomThresholdSet` block per variant. Per-variant Harrell-Davis P10 (bottomAngle = of min_knee), P90 (startAngle = of max_knee), P50 (endAngle = of max_knee) with MAD outlier rejection, BCa 95% CI (1 000 resamples), and ICC design-effect correction (session as cluster). Imports its statistics helpers (`hd_percentile`, `bca_ci`, `design_effect`) from `derive_thresholds_from_telemetry.py` (the curl script) so a fix to the math lands in one place. Auto-saves to `data/telemetry/derived/<stem>_squat_thresholds.txt` when invoked with a file path; stdin invocations are terminal-only. Enforces the FSM invariant `startAngle > endAngle > bottomAngle` and flags violations with `⚠ INVARIANT VIOLATION`. |
| **Hip-lead audit criterion** | The Part-4 audit reports a session-aggregate "Hip lead" criterion: `evaluated = repsTotal`, `fired = errorCounts[FormError.hipLead] ?? 0` (clamped to `repsTotal`). Session-aggregate because the `form_errors` SQLite table doesn't carry per-rep linkage. A future schema bump that persists per-rep error linkage would let this criterion become per-rep like the others; until then it's a session-level summary. |

---

## 13g'. Push-Up Telemetry Threshold Tuning (2026-05-13)

Vocabulary added alongside the push-up `pushup.rep` telemetry channel and its companion offline derivation script. Mirrors the squat tuning workflow (§ entries above) — terms below have exactly one home in code.

| Term | Definition |
|---|---|
| **`pushup.rep` telemetry line** | `TelemetryLog` line emitted by `WorkoutViewModel._handlePushUpRepCommit` once per committed push-up rep. Fixed-order key=value tokens: `rep=<int> min_elbow=<f\|null> max_elbow=<f\|null>`. Always-on (not gated on a debug-session toggle) — production data feeds the offline ROM-derivation script. Consumed by `parse_pushup_rep_lines` (regex `_PUSHUP_REP_RE`) in `derive_pushup_thresholds_from_telemetry.py`. Adding new fields requires a lock-step update to the Python regex. |
| **`_OnPushUpRepCommit`** | Library-private typedef in `app/lib/engine/rep_counter.dart`. Signature: `void Function({required int repIndex, required double? minElbowAngle, required double? maxElbowAngle})`. Fires from `RepCounter._onPushUpCommit` after the quality accumulation runs. Trimmed vs the squat commit shape — `body_line_dev` / `quality` are not consumed by v1 derivation; add them only when a form-threshold derivation function exists. The underscore prefix mirrors Dart library-private convention; external callers (`WorkoutViewModel`) pass a method tearoff so the name never has to cross library boundaries. |
| **`formatPushUpRepLine`** | Pure-Dart top-level function in `app/lib/view_models/telemetry/pushup_rep_line.dart`. Renders the `pushup.rep` line shape verbatim. Lives outside `workout_view_model.dart` so the format contract can be unit-tested with `flutter_test`'s pure-Dart surface (no `pumpWidget`). Null angles render as the literal string `"null"` — the Python parser's regex anchors on fixed-order tokens, never optional fields. Any change to the emitted shape requires updating `_PUSHUP_REP_RE` in `derive_pushup_thresholds_from_telemetry.py` in the same PR. |
| **`PushUpRepRecord`** | Python `dataclass` in `tools/dataset_analysis/scripts/derive_pushup_thresholds_from_telemetry.py`. Fields: `session_idx`, `min_elbow`, `max_elbow`. The parsed counterpart of one `pushup.rep` line. `session_idx` indexes the `curl_debug.session_start`-delimited block this rep was found in; pastes without markers all land in cluster 0 and the ICC design-effect correction collapses to deff=1.0. |
| **Push-up telemetry derivation script** | `tools/dataset_analysis/scripts/derive_pushup_thresholds_from_telemetry.py`. Consumes `min_elbow` / `max_elbow` from the `pushup.rep` telemetry stream and emits a paste-ready Dart `PushUpRomThresholdSet` block per **sensitivity tier**. Percentile sweep diagonal: `high → P15/P85`, `medium → P10/P90 (recommended)`, `low → P5/P95` (future tier). Shallow gate at P25 of `min_elbow`. Uses HD percentiles, MAD 3.5× rejection per-dimension, BCa 95% CI (1 000 resamples), and ICC design-effect correction (session as cluster). Statistics helpers (`hd_percentile`, `bca_ci`, `design_effect`) imported from `derive_thresholds_from_telemetry.py` so a fix to the math lands in one place. Auto-saves to `data/telemetry/derived/<stem>_pushup_thresholds.txt` when invoked with a file path; stdin invocations are terminal-only. Enforces FSM invariant `startAngle > endAngle > bottomAngle` and flags violations with `⚠ INVARIANT VIOLATION`. |
| **`PushUpRomDefaults.forSensitivity`** | Sensitivity-keyed cold-start ROM accessor on `app/lib/core/push_up_rom_defaults.dart`. Returns the `_high` tuple for `FeedbackSensitivity.high` and the `_medium` tuple for `.medium`. Replaces the prior "sensitivity does NOT affect push-up ROM gates" doc-block claim (lines 55-58 of the file's pre-2026-05-13 revision). Calibration overrides still apply per-user; sensitivity only shapes the **pre-calibration fallback**. `PushUpRomDefaults.defaults` is kept as a back-compat alias = `_medium` so existing call sites don't churn. Values shipped in this PR are still hand-tuned; the follow-up PR runs the derivation script on real telemetry and replaces them. |
| **Universal session boundary marker** | `curl_debug.session_start`, emitted by `TelemetryLog` when a curl debug session opens. Reused as the **universal** session delimiter across all exercise derivation scripts (curl, squat, push-up). No exercise-specific `<exercise>_debug.session_start` marker exists in v1; push-up parsing uses `curl_debug.session_start` as the cluster boundary for ICC correction. Pastes without markers degrade gracefully to a single cluster (deff → 1.0). **The Push-up Debug Session (2026-05-16) emits this exact marker** in addition to its own human-readable `pushup_debug.session_start` header, so a pasted push-up debug log is split correctly by `derive_pushup_thresholds_from_telemetry.py` (which does `text.split("curl_debug.session_start")`). |
| **Push-up Debug Session** | Silent-observation mode for collecting push-up FSM-threshold telemetry, full parity with the Curl/Squat Debug Sessions. Gated by `kPushUpDebugSessionEnabled` (compile-time, dev-only). When active: suppresses all user-facing feedback (TTS, haptics, banners — via the `isDebugSilent` OR and the `_onFormErrors` early-return), forces `_resolvePushUpThresholds` to return `PushUpRomThresholds.defaults` **unmodified** (tier 3, no sensitivity post-pass — highest-priority override, checked before the global diagnostic toggle), raises the telemetry ring buffer to `kPushUpDebugRingBufferSize`, and emits `pushup_debug.session_active` / `pushup_debug.session_start` / the universal `curl_debug.session_start` / `diagnostic.mode_active` markers. Launched from the home-screen "Push-up Debug Session" tile (sets `pushup_debug_session` pref true) or toggled in Settings; the normal push-up tile (`_startNormalPushUp`) defensively clears the pref so a stale debug flag never leaks into a feedback-on workout. Snapshot-on-construction in `WorkoutViewModel._isPushUpDebugSession` (mid-session Settings toggling does not affect an in-flight workout). Pref persisted via `PreferencesRepository.get/setPushUpDebugSession` (SQLite + in-memory). Reset of the ring-buffer cap happens in `dispose()`. |
| **Show Debug Tools** | A single user-facing master visibility gate (Settings → *Diagnostics & Advanced* → "Show debug tools") for the three home-screen "Debug Session" entry cards (Curl / Squat / Push-up). **Defaults to `true`** (visible) — deliberately the opposite empty-row default of every per-exercise debug pref — so developer builds keep the tools; the developer flips it OFF before handing the app to a real user. Persisted via `PreferencesRepository.get/setShowDebugTools` (SQLite key `show_debug_tools` + in-memory; getter returns `true` when the row is absent). Read in `_TrainTab` via a `FutureBuilder<bool>` that wraps the three `kXDebugSessionEnabled` card blocks; the compile-time consts remain the OUTER gate and this pref is the ANDed runtime gate. Pending state resolves to **hidden** so a real user (pref OFF) never sees a debug-card flash. **Visibility only** — does not alter debug-session behavior once launched, and is independent of the per-launch `curl_debug_session` flag. Added 2026-05-16. |

---

## 13h. Demo Mode & Onboarding Gate (2026-05-13)

The canonical vocabulary for the first-launch demo prompt + Settings toggle + canonical seed feature documented in `plans_of_claude/demo-mode-toggle.md`. Schema v10. Every term below has exactly one home in code — adding a synonym is a regression.

| Term | Definition |
|---|---|
| **Demo Mode** | The system-wide toggle that, when on, populates the app with "Demo Alex" — a canonical persona + 14 sessions across the last 21 days — so the dashboard, history, and profile surfaces look lived-in. Backed by the `demo_mode_enabled` preference. Distinct from "demo build" or "preview build" (which mean compiled artifacts) — Demo Mode is a runtime data state, not a build flavor. |
| **`DemoService`** | `app/lib/services/demo/demo_service.dart`. Imperative API with `isEnabled`, `enableAndSeed`, `disable`, `recordOnboardingChoice`, `cleanReseedIfStale`. Holds refs to the four repos. Every telemetry event it fires is tagged `data: {'is_demo': true}` so future analytics can filter (per Gap 9). |
| **`DemoSeed`** | `app/lib/services/demo/demo_seed.dart`. Pure-Dart, deterministic blueprint builder. Public static method `DemoSeed.build({DateTime? now})` returns a `DemoBlueprint`. Day-N offsets are computed against `now ?? DateTime.now()`; per-rep jitter is Knuth's multiplicative hash so identical `now` produces identical byte output. The blueprint in code is the source of truth — there is no JSON asset (per ADR-1). |
| **`DemoBlueprint`** / **`DemoSessionBlueprint`** | Value objects returned by `DemoSeed.build`. `DemoBlueprint` carries the `UserProfile` + list of `DemoSessionBlueprint` + three ROM profiles (`curlProfile`, `squatProfile`, `pushUpProfile`). Each `DemoSessionBlueprint` carries three named-column row maps (`sessionRow`, `repRows`, `formErrorRows`) ready for `SessionRepository.insertSeededSession`. |
| **`is_demo` flag** | Schema-v10 `INTEGER NOT NULL DEFAULT 0` column on `sessions` and `user_profile`. `1` = row owned by Demo Mode (wiped on `disable()`); `0` = real user data (untouched). `reps` + `form_errors` are NOT tagged — they cascade-delete with their parent `sessions` row via FK ON DELETE CASCADE. Per ADR-2 the `profiles` table also doesn't get the column — demo ROM profiles use the **demo profile key prefix** instead. |
| **Demo profile key prefix** | The `demo_curl_profile_v1`, `demo_squat_profile_v1`, `demo_push_up_profile_v1` keys in the `profiles` table. ADR-2 kept the keyspace separation for forward compatibility, but **current builds never write into this keyspace** — operator decision (2026-05-13 followup): Demo Mode uses cold-start `RomThresholds.global` defaults so workouts started during demo behave identically to a fresh user's first workout. `deleteDemoProfiles()` is still called defensively by `enableAndSeed` step 3 and `disable` step 2 to wipe any rows left over from older builds. |
| **`onboarding_choice_made`** | Preference key (default `false`). Set to `true` the first time the user answers `FirstLaunchDemoDialog`. The minimal gate from ADR-4 — replaced when Phase 2's full onboarding flow lands. |
| **`user_profile_backup`** | Preference key holding a JSON-encoded snapshot of the user's real `user_profile` row, captured by `enableAndSeed()` step 1 before Demo Alex overwrites it. Restored by `disable()` step 3 Case A. Cleared after restore. The mechanism that makes the `user_profile` singleton round-trip losslessly through enable→disable cycles (per Gap 33). |
| **`cleanReseedIfStale`** | `DemoService` method called from `_bootstrapServices` BEFORE the `FutureBuilder` resolves (per Gap 20 ordering). No-op if demo is off OR the newest demo session is within `kDemoStalenessThreshold` (36 h). Otherwise re-runs `enableAndSeed()` so "Day -1" is always roughly yesterday from the user's perspective. |
| **`saveAsDemo` / `saveAsReal` / `save`** (UserProfileRepository) | Three explicit save methods per ADR-8. `saveAsDemo` forces `is_demo=1` (used by `enableAndSeed` step 4). `saveAsReal` forces `is_demo=0` (used by `disable` step 3 backup-restore AND by `EditProfileScreen._save()` — user-driven saves always promote the row to real, per Gap 34). `save` does a read-modify-write of the existing flag for infrastructure paths that need flag-preservation semantics. |
| **`insertSeededSession` / `deleteDemoSessions`** | `SessionRepository` methods. `insertSeededSession` takes three named-column maps and writes them in a single transaction — bypasses `insertCompletedSession` so the demo seed never has to construct a `WorkoutCompletedEvent` (per ADR-6). `deleteDemoSessions` runs `DELETE FROM sessions WHERE is_demo = 1` (cascades to reps + form_errors). |
| **`FirstLaunchDemoDialog`** | `app/lib/widgets/demo/first_launch_demo_dialog.dart`. Non-dismissible AlertDialog with "Use demo data" / "Start fresh". Fired exactly once via `_OnboardingGate` (`app/lib/app.dart`) on the first cold boot per device, gated by `onboarding_choice_made`. |
| **Effective ROM profile (RETIRED)** | The `_effectiveCurlProfile` / `_effectiveSquatProfile` union helpers in `home_screen.dart` were removed in the 2026-05-13 followup that made Demo Mode skip ROM-profile seeding entirely. Badge logic now reads the live keys directly. Settings ROM sections likewise dropped the demo fallback + "Sample data is providing your calibration" banner. Plan Gaps 15 / 17–19 / 32 are superseded — see the operator decision row in the same section. |
| **`excludeDemo`** | Parameter on `SessionExporter.exportToTempDir` / `sessionsCsv` / `repsCsv`. Defaults to `true`: demo rows are filtered before CSV serialization. Prevents Demo Mode's 14 seeded sessions from leaking into developer support shares (Gap 23 / ADR-9). Reads `SessionSummary.isDemo`, the plumbed column from the schema-v10 `sessions.is_demo`. |
| **DEMO chip** | A cyan badge rendered next to the exercise label on any session card whose `summary.isDemo == true`. Lives in `_SessionRow` (home_screen.dart's History tile) and `SessionCard` (widgets/session_card.dart). **Supersedes ADR-5** of the original plan: explicit demo labeling won over the "lived-in app illusion" in operator review. Demo rows remain read-only — `Dismissible` is skipped on both `_HistorySessionList` (home shell) AND `history_screen.dart`'s list, so the only way to remove demo data is the Settings → Sample Data toggle. |
| **`DemoService.revision`** | `ValueListenable<int>` that bumps on every `enableAndSeed`/`disable` completion. `_HomeScreenState` listens via `_onDemoRevisionChanged` and reloads the dashboard + History on every bump. Closes the empty-state flash when first-launch onboarding picks "Use demo data" — the dashboard auto-refreshes once `enableAndSeed` lands without waiting for the user to navigate away and back. |
| **`DemoService.notifyExternalRefresh()`** | Public method that bumps the same `revision` notifier from a caller outside `DemoService`. Used by `_OnboardingGate._maybeShow` after the auto-pushed `EditProfileScreen` pops, so the dashboard hero refreshes immediately on Save. Closes E17 of `docs/plan/2026-05-13-feat-start-fresh-auto-push-edit-profile-plan.md`. Safe to call even when the user dismissed the form without saving — the triggered `_homeVm.load()` reads the DB and finds the row is still null, a no-op refresh. |
| **"Start fresh" auto-push** | When the user picks "Start fresh" at the first-launch welcome dialog AND no `user_profile` row exists, `_OnboardingGate._maybeShow` auto-pushes `EditProfileScreen` on top of the Dashboard. Uses `Navigator.push` so the back gesture pops cleanly to the Dashboard — the form is a strong suggestion, not a wall. The user can dismiss without saving and the app remains fully functional in its anonymous state. See `docs/plan/2026-05-13-feat-start-fresh-auto-push-edit-profile-plan.md` for the 22-row edge-case enumeration. |

---

## 13j. Reset Sessions (2026-05-21)

| Term | Definition |
|---|---|
| **`SessionRepository.deleteRealSessions()`** | Wipes every row in `sessions` where `is_demo = 0`. Cascades to `reps` + `form_errors` via the existing FK `ON DELETE CASCADE`. Does NOT touch the `profiles` table — calibration is preserved across a session reset. Returns the count of `sessions` rows deleted (excludes cascaded children). Symmetric counterpart to `deleteDemoSessions()` (which wipes `is_demo = 1` and is called by `DemoService.disable`). Added 2026-05-21. |
| **Settings → Reset sessions** | User-facing action in `Settings → Diagnostics & Advanced`. Tap shows a confirmation `AlertDialog`; on confirm, calls `sessionRepository.deleteRealSessions()`, emits a `settings.reset_sessions` telemetry entry, calls `DemoService.notifyExternalRefresh()` so the home dashboard re-queries, and shows a SnackBar with the deleted count. Preserves demo data (`is_demo = 1` rows) AND personal ROM profiles. The existing per-exercise `Recalibrate` / `Reset Profile` controls remain the canonical way to clear ROM profiles. Added 2026-05-21. |
| **`settings.reset_sessions`** | Telemetry-log line emitted from `_confirmResetSessions` after a successful wipe. Payload shape: `deleted=N` (the count returned by `deleteRealSessions`). Lets the diagnostics ring buffer record the operator action without needing to re-query the DB. |

---

## 13i. Plank Exercise + Predefined Targets (2026-05-17)

| Term | Definition |
|---|---|
| **`ExerciseType.plank`** | Fourth exercise type added in `app/lib/core/types.dart`. Time-hold exercise (not rep-counted). Allows landscape orientation (`allowsLandscape` returns `true`). Uses the same `ExerciseRequirements` landmark set as push-up (upper-body: landmarks 11–16). |
| **`PlankStrategy`** | FSM strategy in `app/lib/engine/plank/plank_strategy.dart`. Counts elapsed hold time (seconds) rather than reps. Emits form errors during the hold phase without ending the rep on error — the hold continues until the target duration or the user manually stops. |
| **`PlankFormAnalyzer`** | Form-error classifier in `app/lib/engine/plank/plank_form_analyzer.dart`. Emits two errors: `FormError.plankArmAngle` (elbow angle or shoulder–elbow stack outside the hold window) and `FormError.plankBodyLine` (shoulder–hip–ankle alignment lost during hold). |
| **`FormError.plankArmAngle`** | Plank-specific form error: the user's elbow angle or shoulder-elbow vertical stack has drifted outside the configured hold window. Defined in `app/lib/core/types.dart`. |
| **`FormError.plankBodyLine`** | Plank-specific form error: the shoulder–hip–ankle collinearity is broken during the hold — indicating hip sag or pike. Defined in `app/lib/core/types.dart`. |
| **`ExerciseTargetConfig`** | Value class in `app/lib/core/exercise_targets.dart`. Holds `presets` (list of quick-pick values), `min`, `max`, `defaultValue`, and `isTimed` (true for plank, false for rep-based exercises). `forExercise(ExerciseType)` returns the config for any exercise. `sanitize(int?)` clamps an arbitrary value to the valid range. `labelFor(int)` renders "N reps" or "N sec (M:SS)". |
| **`isTimed`** | Boolean flag on `ExerciseTargetConfig`. When `true` the target is a duration in seconds (plank); when `false` the target is a rep count (curl, squat, push-up). Controls how the home-screen picker renders presets and how the session auto-end logic compares progress against the target. |
| **Session auto-end** | Behavior added 2026-05-17: when the user's rep count (or elapsed hold time for plank) reaches the selected target, the workout session ends automatically without requiring the user to tap Stop. Implemented in `workout_view_model.dart` + `workout_screen.dart`. |
| **`SessionSummaryViewModel`** | New `ChangeNotifier` in `app/lib/view_models/session_summary_view_model.dart`. Encapsulates plank-specific summary logic (hold time, form-error timeline) so `SummaryScreen` does not need plank-specific branches at the widget level. |

---

## 14. Retired / Deprecated Terms

When a term is retired, move its entry here with a `→ replacement` line and the retirement date. Do not delete outright — old commits still reference it.

| Retired term | Retired on | Replacement |
|---|---|---|
| **`FormError.elbowRise`** + the whole curl elbow-rise stack (`kElbowRiseThreshold = 0.22`, `kQualityElbowRiseMaxDeduction = 0.15`, `kFormMinMovementRiseRatio = 0.08`, `FormThresholds.elbowRiseThreshold`, `FormThresholds.effectiveRiseDeadband`, `CurlFormAuditDefaults.elbowRiseThreshold`, `BicepsSideRepMetrics.elbowRiseRatio`, `RepRow.bicepsElbowRiseRatio`, `CurlSideFormAnalyzer._maxElbowRiseRatio`, `CurlSideFormAnalyzer._baselineElbowRelY`, `CurlFormAnalyzerExtras.maxElbowRiseRatioThisRep`, `reps.biceps_elbow_rise_ratio` SQLite column, Form-Audit "Elbow rise" criterion, Summary-screen "Elbow rise" stat row, summary-insight "Your elbow rose…" string, telemetry `elbow_rise_ratio` token in `rep.side_metrics`, the `'Elbow down'` TTS cue, the `arrow_upward_rounded` icon entry, all settings-help copy mentioning "elbow rise") | 2026-05-20 (Curl elbow-rise retirement) | **`FormError.elbowDrift` is now the sole elbow-related curl form audit.** Elbow rise was a side-view-only cheat detector with thresholds (0.12 pre-retune, then 0.22 post-retune) that either flagged textbook reps as faults or failed to discriminate front-delt cheats cleanly. Unlike the project's usual enum-tombstone pattern (`trunkTibia`, `bicepsCurlFront`, DTW), this is a **clean delete** — the enum value, the SQLite column, and every constant are gone, not preserved as `@Deprecated`. Authorized by the user as a dev-mode wipe (no production data to preserve). SQLite schema bumped `v10 → v11` (`app/lib/services/db/schema.dart`) with a portable table-rewrite migration that drops `reps.biceps_elbow_rise_ratio` on existing dev installs. Quality scoring no longer deducts the 15% elbow-rise penalty, so typical curl rep quality scores may drift upward for users who previously triggered the cue — a deliberate quality recalibration, not a bug. Tests that referenced `FormError.elbowRise` as a generic curl-only error (TTS verbosity, session-summary filter) migrated to `FormError.shoulderShrug`. |
| **`FormError.lateralAsymmetry`** (generic "Even out both arms") | 2026-04-21 (Curl Hardening Phase 7 / F6) | `FormError.asymmetryLeftLag` / `FormError.asymmetryRightLag`. The directional split surfaces which arm lagged by preserving the sign of `(left − right)` at the insertion site (the record type `({double left, double right})`). The old generic cue is gone from code; this row is the historical pointer for commits prior to Phase 7. |
| **`FormError.shortRom`** (generic "Full range of motion") | 2026-04-21 (Curl Hardening Phase 8 / F7) | `FormError.shortRomStart` (start not extended enough) / `FormError.shortRomPeak` (peak not deep enough). Classification uses the `RomThresholds` pushed via `setActiveThresholds` at IDLE→CONCENTRIC, compared against numeric extremes captured during the rep and passed through the widened `onAbortedRep({maxAngleAtStart, minAngleReached})`. Peak-short takes precedence. The old generic cue is gone from code; this row is the historical pointer for commits prior to Phase 8. |
| **`CurlRomProfile.calibrationSkipped`** (persisted opt-out flag) | 2026-04-21 (Calibration-Opt-In invariant) | Field removed. With personal calibration now **opt-in only** (never auto-launched), there is no auto-prompt for the user to dismiss, so the persisted opt-out flag has no purpose. `WorkoutScreen._init` enters the calibration phase iff `forceCalibration == true` (the Settings / in-workout-gear entry). `fromJson` silently ignores the legacy key on disk; `toJson` stops writing it. No schema bump — old profiles load without migration. |
| **`FormError.trunkTibia`** (squat trunk-tibia parallelism cue) | 2026-04-25 (Squat Master Rebuild) | `FormError.excessiveForwardLean` (signed, variant-aware). The retired check was a parallelism-deviation rule (`|θ_trunk − θ_tibia| > 15°`) anchored on a single 2-segment proxy; the replacement is an absolute trunk-from-vertical angle with separate thresholds per `SquatVariant` (Bodyweight 45° / HBBS 50°) and a measurement-noise margin from Heliyon 2024 2D-RMSE. **The enum value is RETAINED** so legacy WP5 session rows continue to deserialize via `FormError.values.byName('trunkTibia')` — see `app/test/services/db/legacy_session_compat_test.dart`. New code never emits it; the Summary screen renders pre-rebuild rows under an italicized "Form check (legacy)" subhead, conditional on at least one such row existing. |
| **DTW Reference Rep Scoring** (`DtwScorer`, `DtwScore`, `DefaultReferenceReps`, `ReferenceRepSource`, `ConstReferenceRepSource`, **Form Match card**, `enable_dtw_scoring` preference, `RepRow.dtwSimilarity`, `WorkoutCompletedEvent.dtwSimilarities`, `RepCounter.scoreCurlRep`, `CurlStrategy.scoreRep`, `CurlFormAnalyzer{Extras}.scoreRep`, the "Reference Rep Scoring (Beta)" Settings switch, the per-rep DTW badge above quality bars) | 2026-05-13 | **Form Audit** (`FormAuditor`, `FormAudit`, `CriterionResult`, `_buildFormAuditCard` — see §13c). The reference traces shared provenance with the shelved pipeline-derived thresholds rather than the shipping telemetry-derived thresholds, so DTW was grading against an out-of-date baseline. The replacement re-applies the High-sensitivity form thresholds to each rep's already-persisted maxes — same source of truth as the live FSM, with a per-criterion actionable breakdown instead of an opaque scalar. **The `dtw_similarity` SQLite column is RETAINED** (SQLite can't drop columns without a table rewrite); all post-2026-05-13 writes leave it NULL. Files `engine/curl/dtw_scorer.dart`, `core/default_reference_reps.dart`, `services/reference_reps/reference_rep_source.dart` deleted along with their `test/` siblings. |
| **Strict Mode Recap** (`StrictModeRegrader`, `StrictRecap`, `_buildStrictRecapCard`, file `engine/strict_mode_regrader.dart`, card title "Strict mode recap") | 2026-05-13 (same day as introduction — naming-only refactor) | **Form Audit** (§13c). "Strict mode" implied an opt-in mode the user enters; the feature is actually a post-session retrospective grade that's always on. Renamed for honesty; semantics and behavior unchanged. Also extended in the same change to cover squat + push-up (was curl-only). |
| **Push-Up Hold-and-Average Calibration Protocol** (`_PushUpCalibrationStage.topHold` / `.bottomHold` / `.rise`, `kPushUpCalibrationHoldSeconds`, `kPushUpCalibrationHoldMaxSpread`, `_trackPushUpCalibrationHold`, `_angleSpread`) | 2026-05-15 | **Push-Up Observe-Reps Protocol** (§1). The original protocol asked the user to statically hold each endpoint for 3 seconds while a spread check rejected wobbly samples, then averaged the held samples. Held angles consistently drifted higher than the user's actual rep extremes (held lockout ≠ rep lockout), so the derived thresholds were stricter than what real reps would hit — the dominant cause of dropped rep counts post-calibration. The two `kPushUpCalibrationHold*` constants are RETAINED in `constants.dart` because telemetry-derivation scripts in `tools/dataset_analysis/` reference them; the new protocol does not read them. The stage names `topHold` / `bottomHold` / `rise` no longer exist in code — they're replaced by `observeReps` / `confirm`. |

---

## 15. Maintenance Duty

- This file is updated in the **same PR** that introduces a new term.
- When the brain's `WISDOM.md` adds a vocabulary-lock entry, mirror it in §1 or add a category here.
- Every quarter, scan the last 3 months of commits for uncovered terms and backfill.
- If this file and the code disagree, **the code wins** — but open a follow-up to decide which should change.

> **Verification stamp — 2026-05-16 (deep brain reconciliation):** §4.1
> (FormError table) spot-checked against `app/lib/core/constants.dart` and
> `app/lib/core/types.dart` — every cited gate (`kPushUpStartAngle=150`,
> `kPushUpEndAngle=160` hysteresis invariant, `kSquatBottomAngle=80`,
> `kCurlPeakAngle=70`), every `FormError` case (incl. `kneeLedDescent` /
> `kneeDominantPattern` cue-only, squat/push-up tempo+fatigue families), and
> the two-valued `FeedbackSensitivity` all **match the code as written**.
> GLOSSARY.md and SKILLS.md were found *current* — the same-PR Glossary Duty
> held even though `STATE.md`/`STRUCTURE.md`/`ROADMAP.md`/`TECH_STACK.md` had
> drifted ~4 weeks (those four were rebuilt this session). Lesson: vocabulary
> discipline worked; snapshot discipline did not — see `WISDOM.md` 2026-05-16
> "brain snapshot drift" entry.
