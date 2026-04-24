# Pipeline Runbook — End-to-End

> Every command you need to go from "empty `data/videos/` folder" to
> "new thresholds shipped in `app/lib/core/default_rom_thresholds.dart`."
> Copy-paste friendly. Assumes a macOS / Linux shell.

---

## 0. One-time setup

### 0.1 Python environment

```bash
cd tools/dataset_analysis

# Create an isolated virtualenv — Python 3.11 is the pinned version, but
# 3.12–3.14 also work for the pure-Python bits.
python3 -m venv .venv
source .venv/bin/activate

# For running tests only (no video processing):
pip install pytest

# For the full pipeline (video extraction, plots, notebook):
pip install -r requirements.txt
```

`requirements.txt` pins:

- `mediapipe==0.10.18` — pose landmarker
- `opencv-python==4.10.0.84` — video reading
- `numpy==1.26.4`, `pandas==2.2.3`, `matplotlib==3.9.2` — analysis
- `jupyter==1.1.1` — notebooks
- `pytest==8.3.3` — tests

### 0.2 Flutter environment (for Phase E replay)

```bash
# Make sure Flutter is on PATH (stable channel ≥ 3.11 matches app/pubspec.yaml)
flutter --version

cd tools/dataset_analysis/dart_replay
flutter pub get   # resolves the path: dep on ../../../app
flutter analyze   # should report 0 issues after pub get
```

---

## 1. Phase B — Extract keypoints

### 1.1 Drop videos in

Videos go in `data/videos/` with the naming convention:

```
clip_{nnn}_{subject_id}_{view}_{side}.mp4
```

Example: `clip_042_subj_a_side_right.mp4` = clip number 42, subject A,
side view, right arm working.

See [`07_recording_guide.md`](07_recording_guide.md) for how to actually
record clips that produce usable data.

### 1.2 Extract one video

```bash
cd tools/dataset_analysis
source .venv/bin/activate

python scripts/extract_keypoints.py --video data/videos/clip_042_subj_a_side_right.mp4
```

Output: `data/keypoints/clip_042_subj_a_side_right.jsonl`.

### 1.3 Extract everything

```bash
python scripts/extract_keypoints.py --all
```

Skips clips whose JSONL is already newer than the video (`is_stale`
check). Use `--force` to re-extract everything.

**Expected runtime:** ~3–5× realtime on M-series Mac, ~0.5× realtime on
CPU-only x86. The Heavy model is deliberately slow; we run it once per
clip and cache the output.

### 1.4 Verify the extraction

```bash
head -1 data/keypoints/clip_042_subj_a_side_right.jsonl | python -m json.tool
```

You should see:

```json
{
  "frame": 0,
  "t_ms": 0,
  "landmarks": [
    {"x": 0.51, "y": 0.23, "z": -0.12, "v": 0.98},
    ... 33 landmarks ...
  ]
}
```

---

## 2. Annotation (gates Phase C onward)

Two paths — auto (recommended) or manual. Full details in
[`data/annotations/README.md`](../data/annotations/README.md) and
[`03_phase_B_extraction.md`](03_phase_B_extraction.md#annotation).

### 2.1 Auto-annotate from a clip-level quality label (recommended)

Shoot clips that are quality-homogeneous (every rep in the clip is the same
quality). Label each clip once in `videos.csv` via `intended_quality`, then
let the script derive `reps.csv` from the smoothed elbow-angle signal.

**videos.csv** (one row per clip, `intended_quality` populated):
```csv
clip_id,subject_id,view,side,arm,fps,intended_quality,notes
clip_042_subj_a_side_right,subj_a,side,right,right,30,good,good lighting
clip_043_subj_a_side_right,subj_a,side,right,right,30,bad_swing,intentional torso English
```

Run auto-annotation:
```bash
python scripts/phase_b_auto_annotate.py --review
```

This walks each clip's smoothed elbow-angle series and emits
`(start_frame, peak_frame, end_frame)` triples at every rest → peak → rest
cycle that passes the **40° excursion gate** and **8-frame dwell gate**
(mirrors the shipping Dart `rep_boundary_detector`). Per-rep `quality` is
inherited from `videos.intended_quality`.

`--review` prints a per-clip rep count summary to stderr. If the detected
count is off by more than a rep or two for any clip, spot-check that clip
visually before proceeding.

### 2.2 Manual annotation (fallback)

Use when a clip mixes rep qualities, or when you want to lock in explicit
ground truth for a replay-validation clip.

**videos.csv** (leave `intended_quality` blank):
```csv
clip_id,subject_id,view,side,arm,fps,intended_quality,notes
clip_042_subj_a_side_right,subj_a,side,right,right,30,,good lighting
```

**reps.csv** (one row per rep, hand-written):
```csv
clip_id,rep_idx,start_frame,peak_frame,end_frame,quality
clip_042_subj_a_side_right,1,15,47,78,good
clip_042_subj_a_side_right,2,92,125,156,good
clip_042_subj_a_side_right,3,170,199,228,bad_partial_rom
```

`quality` values: `good`, `bad_swing`, `bad_partial_rom`, `bad_speed`.
Only `good` reps feed the percentile math.

---

## 3. Phase C — Compute per-rep stats

```bash
python scripts/compute_rep_stats.py
```

Reads `data/annotations/*.csv` and `data/keypoints/*.jsonl`. Writes
`data/derived/per_rep_stats.csv` — one row per rep, 22 columns.

**Explore the output (optional but recommended):**

```bash
jupyter notebook notebooks/01_explore_distributions.ipynb
```

The notebook plots histograms of start/peak/end angles, overlays the P20/P75
markers, and breaks down rows per subject so you can catch class imbalance
before it bites the percentile math.

---

## 4. Phase D — Derive thresholds

### 4.1 Run the derivation

```bash
python scripts/derive_thresholds.py
```

Reads `data/derived/per_rep_stats.csv`. Writes
`data/derived/thresholds.json`.

If any FSM invariant is violated (see
[`05_phase_D_threshold_math.md`](05_phase_D_threshold_math.md)), the
script exits with code `1` and prints the violation. Do not proceed
until the violation is understood and resolved.

### 4.2 Review the JSON

Open `data/derived/thresholds.json` and sanity-check:

- **`n`** per threshold should match the number of good reps.
- **CI width** (`ci_high_deg - ci_low_deg`) should be reasonable.
  Anything more than ~15° means the dataset is too small or too noisy
  for a stable estimate.
- **`dataset_summary`** should match your annotation spreadsheet.

### 4.3 Generate the Dart file

```bash
python scripts/generate_dart.py
```

Reads `data/derived/thresholds.json`. Writes
`app/lib/core/default_rom_thresholds.dart`.

**The generated file is committed.** Diff it against the previous
version:

```bash
git diff app/lib/core/default_rom_thresholds.dart
```

Every change to a threshold should be defensible by looking at
`thresholds.json`. If it isn't, stop and investigate.

---

## 5. Phase E — Validate with replay

Before committing the new Dart file, verify it doesn't regress rep-counting
accuracy on the dataset.

```bash
cd tools/dataset_analysis/dart_replay
dart run bin/replay.dart
```

(Requires `flutter pub get` to have been run once; see §0.2.)

Reads `data/keypoints/*.jsonl` + `data/annotations/*.csv`. Writes
`data/derived/validation_report.md`.

**Pass criteria:**

- **Overall F1 ≥ 0.95** across all clips.
- **No clip with F1 < 0.85.** A single clip with poor F1 is either a
  threshold problem or a bad annotation — investigate which.

If F1 drops, do *not* force through. Roll back the thresholds, inspect
the clips that dropped, and iterate.

---

## 6. Commit checklist

Before opening a PR that changes thresholds:

- [ ] `data/annotations/*.csv` — any new annotations included
- [ ] `app/lib/core/default_rom_thresholds.dart` — regenerated, committed
- [ ] `data/derived/thresholds.json` — **not** committed (it's in .gitignore)
      but summarised in the PR description
- [ ] `data/derived/validation_report.md` — not committed but F1 figures
      pasted into the PR description
- [ ] `pytest` passes cleanly
- [ ] `flutter analyze` inside `app/` passes
- [ ] `flutter analyze` inside `dart_replay/` passes

---

## 7. Incremental / iterative runs

The pipeline is designed to be idempotent and incremental:

- **Add a new clip.** Drop the video in, add rows to both CSVs, re-run
  `--all` for extract, re-run the rest top to bottom. `extract_keypoints
  --all` only processes the new clip (staleness check).
- **Relabel a rep.** Edit `reps.csv`, re-run `compute_rep_stats`,
  `derive_thresholds`, `generate_dart`, `replay`. No need to re-extract.
- **Tweak the percentile or margin.** Edit
  `scripts/derive_thresholds.py`, re-run from Phase D. Tests must still
  pass.

---

## 8. Clean rebuild

If anything gets into a weird state:

```bash
cd tools/dataset_analysis

# Nuke derived output (keypoints too if you want a full rebuild)
rm -rf data/derived/*
# rm -rf data/keypoints/*  # only if you really want to re-extract

# Nuke Python bytecode
find . -type d -name __pycache__ -exec rm -rf {} +

# Rebuild
python scripts/extract_keypoints.py --all  # if you cleared keypoints
python scripts/compute_rep_stats.py
python scripts/derive_thresholds.py
python scripts/generate_dart.py
cd dart_replay && dart run bin/replay.dart
```

All outputs are deterministic given the same input, so a clean rebuild
should produce byte-identical results to the previous run.

---

## 9. CI / automation (future)

Not yet wired, but the hooks are all there:

- `pytest` already runs end-to-end in <1s and is safe for CI.
- `derive_thresholds.py` exits non-zero on invariant violations — usable
  as a commit-time gate.
- `generate_dart.py` output can be diffed against committed Dart to
  detect "someone forgot to regenerate" regressions.

See [`06_testing_and_verification.md`](06_testing_and_verification.md)
for what we verify today and what's pending real-data CI integration.
