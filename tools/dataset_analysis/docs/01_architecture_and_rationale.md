# Architecture and Rationale

> **This document explains why the tool looks the way it does.** Every
> directory, every split decision, every non-obvious pattern has a reason.
> Skip to [§3](#3-why-the-splits) if you just want the design decisions.

---

## 1. Directory layout

```
tools/dataset_analysis/
├── README.md                          # TL;DR entry point
├── pytest.ini                         # pythonpath = . (so `scripts.*` imports resolve)
├── requirements.txt                   # Pinned Python deps for reproducibility
├── .gitignore                         # Keeps videos + derived CSVs out of git
│
├── docs/                              # ← you are here
│   ├── 00_overview.md
│   ├── 01_architecture_and_rationale.md
│   ├── 02_pipeline_runbook.md
│   └── ...
│
├── scripts/                           # All Python scripts are importable modules
│   ├── __init__.py
│   ├── angle_utils.py                 # Verbatim port of app/lib/engine/angle_utils.dart
│   ├── landmark_indices.py            # BlazePose 33-index constants
│   ├── jsonl_io.py                    # Shared JSONL reader (FrameSample)
│   ├── extract_keypoints.py           # Phase B: video → jsonl
│   ├── compute_rep_stats.py           # Phase C: per-rep aggregator
│   ├── derive_thresholds.py           # Phase D: percentile + bootstrap math
│   └── generate_dart.py               # Phase D: thresholds.json → .dart file
│
├── tests/                             # Pure-Python unit tests (pytest)
│   ├── test_angle_utils.py
│   ├── test_extract_keypoints.py      # Mocks MediaPipe via fake classes
│   ├── test_compute_rep_stats.py
│   ├── test_derive_thresholds.py
│   └── test_generate_dart.py
│
├── notebooks/                         # Exploration, not committed to CI
│   └── 01_explore_distributions.ipynb
│
├── dart_replay/                       # Phase E: Dart harness (separate pub package)
│   ├── pubspec.yaml                   # path: dep on ../../../app
│   ├── analysis_options.yaml          # excludes bin/** until pub get runs
│   ├── bin/replay.dart
│   └── README.md
│
└── data/                              # All input/output files (most gitignored)
    ├── videos/                        # ← gitignored: raw .mp4 clips
    ├── keypoints/                     # ← gitignored: extracted jsonl
    ├── annotations/                   # ← committed: manual labels
    │   ├── videos.csv
    │   └── reps.csv
    └── derived/                       # ← gitignored: output of the pipeline
        ├── per_rep_stats.csv
        ├── thresholds.json
        └── validation_report.md
```

### 1.1 Why separate Python and Dart worlds?

The Python side handles *analysis*: video decoding, pose estimation,
statistics, plots, threshold derivation. Everything here is inspectable
with standard data-science tooling and can be iterated in a notebook.

The Dart side handles *validation*: it feeds extracted keypoints through
the **real** on-device FSM and reports F1. No FSM logic exists outside of
`app/lib/engine/` — that's the whole point.

If the boundary between the two sides had been different, we'd be
maintaining two state machines and every bug fix on-device would quietly
invalidate our threshold validation. That's a failure mode we rejected on
principle.

---

## 2. Phase-by-phase rationale

### 2.1 Phase A — Skeleton + angle math

**What it does:** ports `app/lib/engine/angle_utils.dart` verbatim to
Python (`scripts/angle_utils.py`), establishes the BlazePose index
constants (`scripts/landmark_indices.py`), and stands up the directory
skeleton.

**Why verbatim port?** The elbow-angle calculation is the single most
important numeric function in the whole pipeline: if the Python side
computes "elbow = 62°" where the Dart side would say "elbow = 58°,"
every downstream percentile is wrong. So we don't rewrite the formula in
a more idiomatic Python style — we copy it, line for line, including the
3-frame moving-average smoother in its exact shape. The test suite then
asserts against known-trig values (right angle, straight arm, etc.) so a
typo in the port fails loudly.

**Why landmark indices in a separate file?** MediaPipe and ML Kit share
the BlazePose schema, so the indices are the same number in Python and
Dart. But they're defined in *different* files (`landmark_types.dart` vs.
`landmark_indices.py`) and we want a single contract. The test
`test_video_extensions_contract` + the inline comment "mirrors
app/lib/models/landmark_types.dart" are the tripwires: any reordering in
the Dart source must be mirrored in Python in the *same commit*.

### 2.2 Phase B — Video → keypoints JSONL

**What it does:** reads a video with OpenCV, feeds each frame to
MediaPipe Pose Landmarker (`model_complexity=2`, aka the Heavy variant),
and writes one JSON line per frame to `data/keypoints/{clip_id}.jsonl`.

**Why JSONL, not Parquet or HDF5?**
- JSONL is `git diff`-friendly — you can literally open the file and
  read it.
- Every downstream consumer (Python via `jsonl_io.py`, Dart via
  `bin/replay.dart`) can parse it with stdlib JSON.
- The files are one-time artefacts — we never need to mutate them.

The on-disk schema is tiny and deliberately flat:

```json
{"frame": 42, "t_ms": 1400, "landmarks": [{"x":0.51,"y":0.32,"z":-0.10,"v":0.98}, ...]}
```

**Why MediaPipe Heavy?** Real-time on-device inference uses ML Kit
Accurate or MoveNet Lightning — both are lighter-weight. For *offline*
threshold derivation we do not have a latency constraint, so we use the
highest-accuracy model available. That lifts the signal-to-noise ratio of
the derived percentiles. At runtime the app still runs the lighter
model, but the derived thresholds target the *biomechanical ground
truth* the heavy model is closer to, not the noisy lightweight one.

**Why `static_image_mode=False` + `smooth_landmarks=False`?**
- `static_image_mode=False` lets MediaPipe use temporal tracking, which
  is what the shipping app sees.
- `smooth_landmarks=False` is the critical one. MediaPipe has its own
  optional smoothing; the shipping app does its smoothing downstream in
  Dart using a 3-frame moving average. If we let MediaPipe smooth here
  too, we'd be smoothing twice — the derived percentiles would be
  cleaner than anything the runtime actually sees.

### 2.3 Phase C — Per-rep aggregator

**What it does:** for each `(clip_id, rep_idx)` row in `reps.csv`, windows
the JSONL stream to `[start_frame, end_frame]`, smooths the elbow angle
with the same 3-frame MA as the shipping FSM, and extracts 22 statistics
per rep.

**Why pure Python math, no pandas for the per-rep computation?**
- Every per-rep function (`elbow_angle_for_arm`, `torso_length`,
  `compute_rep_stats`) is easier to unit-test against synthetic
  `FrameSample` fixtures when it takes plain lists and returns plain
  values.
- pandas is used only at the IO boundary (`_read_videos_csv`,
  `write_stats_csv`) and in the notebook.
- This keeps the core pipeline inspectable line-by-line.

**Why 22 fields?** Each threshold derivation in Phase D needs a specific
input column. We also record signals (torso drift, wrist swing) that don't
feed threshold derivation today but are needed for future *form-feedback*
tuning. Carrying them at the CSV boundary costs nothing.

**Why normalise drift/swing by torso length?** A user 1m from the camera
and a user 2m from the camera produce different pixel-space shoulder
excursions for the same real body motion. Dividing by median torso length
(itself in pixel space) cancels the scaling and gives a subject-
independent ratio.

### 2.4 Phase D — Threshold derivation and Dart generation

**What it does:** two scripts in sequence.

1. `derive_thresholds.py` reads `per_rep_stats.csv`, filters to
   `quality='good'`, computes P20/P75/P20 percentiles for
   `start_angle`/`peak_angle`/`end_angle`, applies ±5° safety margins,
   generates 95% bootstrap CIs, runs FSM invariant checks, and writes
   `thresholds.json`.

2. `generate_dart.py` reads that JSON and emits
   `app/lib/core/default_rom_thresholds.dart` with a DO-NOT-EDIT banner
   and dataset-provenance comments.

**Why split into two scripts?** The JSON is the reviewable artefact.
Reviewers look at `thresholds.json` in a PR diff to understand why a
threshold moved. The Dart file is just a rendered view of the JSON —
deterministic and small enough to regenerate from scratch.

Splitting them also means the codegen tests don't have to boot the full
derivation pipeline; they just feed a hand-written JSON fixture to
`generate_dart.py` and assert on the output string.

See [`05_phase_D_threshold_math.md`](05_phase_D_threshold_math.md) for
the full mathematical treatment.

### 2.5 Phase E — Replay harness

**What it does:** a Dart binary that reads the same JSONL files, wraps
each frame into a `PoseResult`, feeds them through a real `RepCounter`
instance, and computes precision/recall/F1 by comparing detected reps to
the annotations.

**Why Dart, not Python?** See [§4.1 in the overview](00_overview.md#41-why-python-for-analysis-and-dart-for-replay)
— the FSM is the single source of truth and cannot be ported.

**Why `path:` dependency?** `pubspec.yaml` points at `../../../app`. When
you run `flutter pub get` inside `dart_replay/`, it resolves
`package:fitrack/...` against the local app directory. There is no
published package; the harness uses the app's live source tree.

**Why the `analyzer.exclude: [bin/**]`?** Those `package:fitrack/...`
imports don't resolve until *after* `flutter pub get` has run, and the
repo-wide `flutter analyze` doesn't run `pub get` inside nested
directories. Excluding the harness from analysis when unresolved keeps
the top-level analyzer green. Once a contributor runs `flutter pub get`
in `dart_replay/`, they should run `flutter analyze` inside that
directory to verify the harness still compiles against the current
engine surface.

---

## 3. Why the splits

### 3.1 Why JSONL not CSV for per-frame keypoints?

A single clip has 33 landmarks × 4 fields × ~900 frames ≈ 120k numbers.
Flattening that to CSV creates a 400+ column row per frame or requires
repeating the row per landmark (exploding disk usage ~30×). JSONL keeps
the nested structure, one row per frame, and stays small.

### 3.2 Why CSV for annotations?

Annotations are *written by humans* in a spreadsheet. CSV is the universal
format for that — Excel, Numbers, Google Sheets, and every text editor
handle it. No tooling required to contribute a label.

### 3.3 Why JSON for thresholds, not CSV?

The derivation output is *structured* (value + CI bounds + n + percentile
+ margin per threshold). CSV would flatten it awkwardly. JSON preserves
the shape and is diff-friendly.

### 3.4 Why generate a Dart file, not read JSON at runtime?

- **Determinism.** `const double` values are known at compile time; no
  runtime file IO, no "did the JSON file ship with the APK?" question.
- **Traceability.** The Dart file is committed. `git blame` shows when
  a threshold changed and which dataset it came from.
- **Fallback.** The JSON lives in `data/derived/` which is gitignored.
  The Dart file is the *committed* record of the derivation.

### 3.5 Why an `__init__.py` and `pythonpath = .` in `pytest.ini`?

Tests import scripts as `from scripts.angle_utils import angle_deg` — i.e.
as a package. This:
- prevents accidental `from angle_utils import angle_deg` inside tests,
  which would break when run from a different cwd
- lets the scripts import each other cleanly (`jsonl_io.py` imports from
  `scripts.angle_utils` etc.)
- is self-documenting: there is one canonical import path

---

## 4. Patterns the code uses consistently

These patterns appear across multiple files. Knowing them saves re-reading
each file from scratch.

### 4.1 Optional-import guards for heavy dependencies

`extract_keypoints.py` starts with:

```python
try:
    import cv2
except ImportError:
    cv2 = None
try:
    import mediapipe as mp
except ImportError:
    mp = None
```

This means `pytest` can import the module for testing without MediaPipe or
OpenCV installed. The real CLI entry points call `_require_runtime_deps()`
which raises a clear error if the dependencies aren't actually available.

**Benefit:** unit tests stay fast and runnable in any Python 3.11+
environment. You only need the heavy dependencies when you actually
process a video.

### 4.2 Dataclass-per-row for CSV IO

`VideoRow`, `RepRow`, `StatsRow`, `RepStats`, `ThresholdEstimate` —
every CSV/JSON record has a `@dataclass(frozen=True)` (or non-frozen
where mutation is needed). This:
- makes fields IDE-discoverable
- gives test fixtures a typed shape
- centralises CSV column ordering via `csv_header()` / `as_csv_row()`

### 4.3 `None`-passthrough discipline

Every helper that could encounter missing landmarks returns `Optional[T]`
rather than raising. `compute_rep_stats` propagates `None` upward for
fields that couldn't be computed rather than failing the whole rep.

The rationale: a single low-confidence frame shouldn't break an entire
set's worth of statistics. Downstream code (percentile derivation) just
filters out Nones.

### 4.4 Deterministic randomness

`bootstrap_ci` takes a `seed` parameter (default `1234`). Two runs on the
same input produce bit-identical CIs. This is essential because the JSON
file is committed and we want clean diffs.

### 4.5 CLI-as-library

Every script has:
- a `main(argv=None)` entry point
- a `build_parser()` factory
- a module-level `__all__` exposing the reusable pieces

This makes it easy to call the same code from a notebook, a test, or a
shell script without forking the logic.

---

## 5. What this pipeline explicitly *doesn't* do

- **It doesn't learn a classifier.** Good/bad reps are human-labelled.
  Any future classifier belongs downstream, not in this tool.
- **It doesn't auto-segment reps.** We intentionally require manual
  `start/peak/end_frame` to avoid circularity (see [§4.3 in overview](00_overview.md#43-why-hand-annotated-reps)).
- **It doesn't write to the database or touch any service.** Pure offline
  analysis, pure file IO.
- **It doesn't run on CI yet.** The tests do, but the full
  video→keypoints→thresholds pipeline needs video fixtures that don't
  exist in the repo. When the dataset lands, a CI hook can validate the
  derivation is idempotent against a canonical set.
