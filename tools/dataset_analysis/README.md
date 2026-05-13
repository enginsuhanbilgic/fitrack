# Dataset Analysis — Reference-Dataset Threshold Derivation

Offline Python pipeline that turns pre-recorded exercise videos into data-driven
defaults for FiTrack's biomechanical FSM constants (Task 2.4).

This directory is **dev-box only**. Nothing here ships in the Flutter app. The
pipeline's only output that touches the app is the generated file
`app/lib/core/default_rom_thresholds.dart`, regenerated on demand.

The authoritative plan for this work lives at
`plans_of_claude/now-prepare-a-comprehensive-enumerated-balloon.md`.

---

## Pipeline at a glance

```
videos (gitignored)
    │
    │  scripts/extract_keypoints.py        (MediaPipe Pose, offline)
    ▼
data/keypoints/*.jsonl               (committed — ground-truth pose data)
    │
    │  scripts/phase_b_auto_annotate.py    (auto rep boundaries from signal)
    │  + data/annotations/videos.csv       (clip metadata + intended_quality)
    │     ───── OR ─────
    │  + data/annotations/reps.csv         (hand-scrubbed boundaries, fallback)
    │
    │  scripts/compute_rep_stats.py
    ▼
data/derived/per_rep_stats.csv       (committed)
    │
    │  scripts/derive_thresholds.py        (percentiles + invariants)
    ▼
data/derived/percentiles.json                    (committed, raw precision)
app/lib/core/default_rom_thresholds.dart         (committed, generated Dart)
    │
    │  dart_replay/bin/replay.dart         (runs shipping FSM on keypoints)
    ▼
data/derived/validation_report.md                (committed)
```

---

## Phase status

This pipeline lands in 5 independently-mergeable phases. See the plan for full
detail. Quick status:

| Phase | Deliverable | Status |
|---|---|---|
| A | Skeleton + `angle_utils.py` port + pytest | 🔨 in progress |
| B | `extract_keypoints.py` + 2-3 sample keypoints committed | ⬜ pending |
| C | Annotation CSVs + `compute_rep_stats.py` + first notebook | ⬜ pending |
| D | Full 20-subject derivation + generated Dart file (orphan) | ⬜ pending |
| E | Dart replay + validation + wire `constants.dart` | ⬜ pending |

---

## One-time environment setup

```bash
cd tools/dataset_analysis
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Verify by running unit tests:

```bash
pytest
```

Expected output: all `test_angle_utils` tests pass.

---

## Common commands

```bash
# Phase B — extract keypoints from one new video
python scripts/extract_keypoints.py --video data/videos/clip_042.mp4 \
                                    --out   data/keypoints/clip_042.jsonl

# Phase B — reprocess any videos whose keypoints are missing or stale
python scripts/extract_keypoints.py --all

# Phase B — auto-annotate rep boundaries from the angle signal
# (inherits per-rep quality from videos.intended_quality)
python scripts/phase_b_auto_annotate.py --review

# Phase C — aggregate per-rep stats from keypoints + annotations
python scripts/compute_rep_stats.py

# Phase D — derive percentile-based thresholds + generate Dart file
python scripts/derive_thresholds.py

# Phase E — run shipping FSM on extracted keypoints, compare vs annotations
cd dart_replay
dart pub get
dart run bin/replay.dart
```

---

## Directory layout

```
tools/dataset_analysis/
├── README.md                           this file
├── requirements.txt                    pinned Python deps
├── .gitignore                          ignores .venv and data/videos/
├── data/
│   ├── videos/                         RAW (gitignored) — .mp4 source clips
│   ├── keypoints/                      COMMITTED — MediaPipe output per clip
│   ├── annotations/                    COMMITTED — manual rep boundaries
│   │   ├── videos.csv                  clip metadata (subject, view, side, fps)
│   │   └── reps.csv                    rep boundaries (start/peak/end + quality)
│   └── derived/                        COMMITTED — intermediate + final
│       ├── per_rep_stats.csv           one row per annotated rep
│       ├── percentiles.json            raw percentile table
│       └── validation_report.md        Dart replay pass/fail matrix
├── scripts/                            Python entry points
│   ├── angle_utils.py                  ported from app/lib/engine/angle_utils.dart
│   ├── extract_keypoints.py            (Phase B — video → keypoints)
│   ├── phase_b_auto_annotate.py        (Phase B — keypoints → reps.csv)
│   ├── compute_rep_stats.py            (Phase C)
│   ├── derive_thresholds.py            (Phase D)
│   └── generate_dart.py                (Phase D)
├── tests/                              pytest suite
│   └── test_angle_utils.py             known-answer tests mirroring Dart
├── dart_replay/                        (Phase E) separate Dart package
└── notebooks/                          (Phases C/E) Jupyter exploratory work
```

---

## Source-of-truth guarantees

The Python angle formula is a **verbatim port** of
[`app/lib/engine/angle_utils.dart`](../../app/lib/engine/angle_utils.dart) —
same clamping, same null-on-low-confidence, same math. If the Dart formula
changes, the Python port must be updated in the same commit and `pytest` must
pass.

The 3-frame moving-average smoother in `scripts/angle_utils.py` matches
[`rep_counter.dart`](../../app/lib/engine/rep_counter.dart) line 167-169
exactly — growing window up to size 3, then sliding. Do not replace with a
numpy convolution or a fixed-width rolling mean; the first two samples would
differ.

The FSM itself is **not** ported — the Dart replay harness in Phase E imports
the real `RepCounter` via a `path:` dependency.

---

## Live-telemetry derivation scripts

Independent of the offline-video pipeline above, three companion scripts derive
per-exercise FSM ROM thresholds from **live-session telemetry pastes**. They
consume `<exercise>.rep` lines emitted by the running app and produce
paste-ready Dart `*RomThresholdSet` blocks. Shared statistics helpers live in
`scripts/derive_thresholds_from_telemetry.py` (curl) — a fix to the math lands
in one place across all three.

| Exercise | Script | Telemetry source | Consumed fields | Dart output |
|---|---|---|---|---|
| Biceps curl | `scripts/derive_thresholds_from_telemetry.py` | `rep.extremes`, `rep.side_metrics` | `min_angle`, `max_angle`, `lean_deg`, etc. | `RomThresholds` updates + form-threshold blocks |
| Squat | `scripts/derive_squat_thresholds_from_telemetry.py` | `squat.rep` | `min_knee`, `max_knee` | `SquatRomThresholdSet` per variant |
| **Push-up** | `scripts/derive_pushup_thresholds_from_telemetry.py` *(new, 2026-05-13)* | `pushup.rep` | `min_elbow`, `max_elbow` | `PushUpRomThresholdSet` per sensitivity tier (high/medium/low) |

Each script auto-tees its output to
`data/telemetry/derived/<input_stem>_<exercise>_thresholds.txt` when invoked
with a file path; stdin pastes (`pbpaste | python -m ...`) print to terminal
only — preserves the "quick experiment" workflow.

```bash
# Push-up: derive sensitivity-tier ROM thresholds from a session paste.
python -m scripts.derive_pushup_thresholds_from_telemetry \
    data/telemetry/sessions/2026-05-13_pushup_session.txt
```

Session boundaries are delimited by the universal `curl_debug.session_start`
marker (also emitted by squat/push-up debug sessions). Pastes without markers
degrade gracefully to a single cluster — the ICC design-effect correction
returns deff=1.0 in that case.
