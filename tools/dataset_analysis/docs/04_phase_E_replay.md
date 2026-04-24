# Phase E — Dart Replay Validation

> Covers `dart_replay/bin/replay.dart` in detail: why it's written in Dart
> rather than Python, how it imports the real `RepCounter`, how it scores
> detected reps against ground truth, and how to read the F1 report it
> produces.

---

## 1. Why Dart, not Python?

Every other phase of this pipeline is Python. Phase E is the exception,
and the reason is **the single-source-of-truth rule**.

The FSM in `app/lib/engine/rep_counter.dart` is the code that counts reps
on every user's phone. It is the most important 400 lines in the whole
project. If we wrote a Python port to validate against:

1. Day 0: the port is line-for-line identical to the Dart FSM.
2. Day 30: someone fixes a bug in `rep_counter.dart` and forgets to
   mirror it into Python.
3. Day 60: the replay harness reports F1 = 0.98.
4. Day 61: actual on-device behaviour is F1 = 0.91 because the Python
   port no longer matches what ships.

Any Python port of the FSM would, over time, silently become a *different*
FSM — and we would be validating the wrong thing.

**Solution:** `dart_replay/pubspec.yaml` depends on the real app via a
`path:` dependency:

```yaml
dependencies:
  fitrack:
    path: ../../../app
```

The harness imports `package:fitrack/engine/rep_counter.dart` and runs
**the exact same FSM** the user's phone runs. There is no porting layer.
There can never be drift.

### 1.1 Trade-off: requires Flutter toolchain

The cost is that Phase E is slower to spin up than Phases A–D. To run
the harness you need:

- Flutter SDK (matches `app/pubspec.yaml` — currently stable ≥ 3.11)
- `flutter pub get` inside `dart_replay/` once (resolves `../../../app`)
- Dart 3 runtime (ships with Flutter)

This is a deliberate trade. The alternative (a Python FSM port that
drifts) would be cheap to build and impossible to trust.

---

## 2. What the harness does

### 2.1 Inputs

- `data/keypoints/{clip_id}.jsonl` — frame-by-frame landmarks
- `data/annotations/videos.csv` — one row per clip (`clip_id`, `fps`,
  `arm`, …)
- `data/annotations/reps.csv` — one row per annotated rep
  (`clip_id`, `rep_idx`, `start_frame`, `peak_frame`, `end_frame`,
  `quality`)

### 2.2 Output

- `data/derived/validation_report.md` — a Markdown table, one row per
  clip plus a totals row.

Example:

```markdown
# Replay Validation Report

| Clip       | TP | FP | FN | Precision | Recall | F1    |
|------------|----|----|----|-----------|--------|-------|
| clip_042   | 10 |  0 |  0 |   1.000   | 1.000  | 1.000 |
| clip_043   |  8 |  1 |  1 |   0.889   | 0.889  | 0.889 |
| **TOTAL**  | 18 |  1 |  1 | **0.947** | 0.947  | 0.947 |
```

---

## 3. How `_replayClip()` works

### 3.1 Feed JSONL frames through `RepCounter`

For each clip, the harness:

1. Reads `videos.csv` to learn the clip's `arm` (left/right/both).
2. Constructs a fresh `RepCounter` instance (one per clip — no state
   bleed between clips).
3. Iterates the JSONL line by line, parsing each row into a
   `PoseResult(landmarks: List<PoseLandmark>)`.
4. Calls `repCounter.onPose(poseResult)` in frame order.
5. Watches `repCounter.snapshot.reps` for new reps — whenever the count
   goes up, it records a `DetectedRep(endFrame: currentFrame)`.

Why watch `snapshot.reps` instead of hooking an internal callback? The
snapshot is the **public API** the app consumes. If we hooked anything
deeper, the harness would validate implementation details that the
on-device code doesn't depend on. Validating via the public API means
the harness catches the same regressions the app would experience.

### 3.2 `endFrame` is what we score

When `RepCounter` increments the rep count, the *current* frame is the
one where the FSM transitioned `ECCENTRIC → IDLE`. That's the end of the
rep — the moment the user's arm has returned to rest. We record that
frame index as the detected rep's `endFrame`.

We deliberately don't try to reconstruct the detected rep's start and
peak — the FSM doesn't expose those. The scoring only needs the endpoint.

### 3.3 Missing landmarks

If a JSONL row has `"landmarks": []` (MediaPipe didn't find a person),
the harness builds a `PoseResult` with an empty landmarks list and still
passes it through. The FSM already handles missing-person frames via the
same code path it uses on-device — we don't special-case them in the
harness.

---

## 4. How scoring works

`_scoreClip()` implements **greedy overlap matching**. For each clip:

### 4.1 Matching rule

A detected rep is a **true positive (TP)** if its `endFrame` falls
within some annotated rep's `[startFrame, endFrame]` window:

```dart
bool isMatch(DetectedRep d, AnnotatedRep a) =>
    d.endFrame >= a.startFrame && d.endFrame <= a.endFrame;
```

The window is generous on purpose — we're validating rep *counting*,
not precise endpoint detection. If the FSM fires within the annotated
rep's bounds, it counted the right rep.

### 4.2 Greedy pairing

For each detected rep (in frame order), find the first *unmatched*
annotated rep whose window contains the detection. Mark both as
matched.

- Detected reps with no match → **false positive (FP)**. The FSM fired
  when the annotator saw no rep.
- Annotated reps with no match → **false negative (FN)**. The FSM missed
  a rep the annotator labelled.

### 4.3 Metrics

```
precision = TP / (TP + FP)     # of detected reps, how many were real?
recall    = TP / (TP + FN)     # of real reps, how many did we detect?
f1        = 2 * P * R / (P + R)
```

Both precision and recall matter here. A rep counter that under-counts
(high precision, low recall) frustrates users who think the app isn't
seeing their reps. A rep counter that over-counts (low precision, high
recall) inflates their workout numbers and misleads progress tracking.
F1 as the harmonic mean penalises both failure modes equally.

### 4.4 What about `quality`?

**All annotated reps count toward scoring**, regardless of `quality`.
The FSM is expected to count every rep the user attempted — even bad
ones. The `quality` label is used only by Phase D (it filters the
percentile math to `good` reps so the thresholds aren't pulled by bad
reps). Phase E treats `good` and `bad_*` as equivalent for counting.

---

## 5. Pass criteria

From [`02_pipeline_runbook.md`](02_pipeline_runbook.md#5-phase-e--validate-with-replay):

- **Overall F1 ≥ 0.95.** Across all clips combined.
- **No clip with F1 < 0.85.** A single bad clip pulls the average but
  might be masked by good clips — this guard surfaces it.

If either gate fails, the thresholds must not ship. Options:

1. Inspect the failing clip — is it a threshold problem or a bad
   annotation? Watch the video alongside the detected-vs-annotated
   rep frames.
2. If it's threshold, iterate: either re-run with more data, or
   adjust the safety margin in `derive_thresholds.py`.
3. If it's annotation, fix `reps.csv` and re-run from Phase C.

**Do not force through.** The whole point of the gate is to catch
regressions before they reach users.

---

## 6. The `analysis_options.yaml` rationale

`dart_replay/analysis_options.yaml` contains:

```yaml
analyzer:
  exclude:
    - bin/**
```

This excludes `bin/replay.dart` from Dart analysis. Why?

`replay.dart` imports `package:fitrack/...` — but those imports resolve
only *after* `flutter pub get` has been run inside `dart_replay/`. In a
fresh clone, or in a CI job that runs `flutter analyze` at the repo
root, the harness would produce 12 `uri_does_not_exist` errors.

Excluding `bin/**` from analysis keeps `flutter analyze` clean at the
repo root while leaving the harness itself fully analysable *after*
you've run `flutter pub get` inside `dart_replay/`. The trade-off: the
harness's own analysis errors are hidden from the top-level run, so
always run `flutter analyze` inside `dart_replay/` explicitly when
touching it.

---

## 7. Running the harness

```bash
cd tools/dataset_analysis/dart_replay

# One-time: resolve path: dependency
flutter pub get

# Run
dart run bin/replay.dart
```

CLI flags (all optional — defaults match the pipeline layout):

| Flag | Default | Meaning |
|---|---|---|
| `--keypoints` | `../data/keypoints` | dir of JSONL files |
| `--videos-csv` | `../data/annotations/videos.csv` | clip metadata |
| `--reps-csv` | `../data/annotations/reps.csv` | annotated reps |
| `--out` | `../data/derived/validation_report.md` | report path |

If a clip is in `videos.csv` but has no JSONL file (extraction not run)
or no entries in `reps.csv` (not annotated yet), the harness skips it
with a warning on stderr. The totals row only reflects clips that were
actually scored.

---

## 8. What the harness does NOT do

- **No per-rep timing validation.** We only score the rep count. If the
  FSM fires 5 frames early or late but still inside the annotated
  window, that's a TP. Timing precision is a different question that
  would need its own metric.
- **No confidence intervals on F1.** The F1 number is a point estimate
  on the dataset you've recorded. To generalise to unseen users you'd
  need more data and a held-out split — out of scope here.
- **No auto-retry with different thresholds.** The harness runs exactly
  one config (whatever `default_rom_thresholds.dart` currently ships).
  Threshold search is the job of Phase D.
- **No GPU/accelerator concerns.** The FSM is pure Dart math — no
  hardware dependencies. The harness runs on any machine with a Dart
  runtime.
