# Troubleshooting

> Known failure modes across all five phases, with symptoms, root
> causes, and fixes. Organised by the phase where the symptom surfaces.
> If you hit something not listed here, add it — this file is meant to
> grow.

---

## Phase A — Setup

### A1. `pip install -r requirements.txt` fails on `mediapipe`

**Symptom:**
```
ERROR: Could not find a version that satisfies the requirement mediapipe==0.10.18
```

**Cause:** MediaPipe binary wheels are pinned to specific Python
versions. The pipeline is pinned to Python 3.11; 3.12 and 3.13 usually
work for pure-Python bits but may fail for mediapipe.

**Fix:**
```bash
# Check your Python version
python3 --version

# If not 3.11, install it (macOS via brew):
brew install [email protected]
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If you only need to run tests (no video extraction), `pytest` installs
cleanly on any Python 3.11–3.14.

### A2. `flutter pub get` fails in `dart_replay/` with "path dep not found"

**Symptom:**
```
Could not find a file named "pubspec.yaml" in "/path/to/fitrack/app"
```

**Cause:** The relative path `../../../app` from
`dart_replay/pubspec.yaml` points outside the repo or to a non-existent
directory. Usually because you moved `dart_replay/` or cloned without
the full repo.

**Fix:** Verify the repo structure:
```bash
ls tools/dataset_analysis/dart_replay/pubspec.yaml  # should exist
ls app/pubspec.yaml                                 # should exist
```

Both must be present and three directories apart. Don't symlink or
relocate `dart_replay`.

---

## Phase B — Video extraction

### B1. Extraction is very slow (~2 fps processing)

**Symptom:**
```
clip_042.mp4: 60 frames (2.1 fps avg)
```

**Cause:** MediaPipe is running on CPU only. On macOS it should use
Metal automatically; on Linux it needs the CUDA build or falls back to
CPU. On Windows the default wheel is CPU-only.

**Fix:**
- **macOS:** usually "just works" with the default wheel. If it doesn't,
  verify you're on Apple Silicon and using a Python built for arm64
  (`python3 -c "import platform; print(platform.machine())"` should
  print `arm64`).
- **Linux:** install `mediapipe` with GPU support (`pip install mediapipe[gpu]` if
  available in the current pin; otherwise use the CUDA-prebuilt wheel).
- **Accept the slowdown:** 2 fps is annoying but not broken. A
  30-second clip takes 7.5 minutes. Run overnight.

### B2. JSONL has 1000 frames but the video is 30 seconds

**Symptom:** Frame count doesn't match `fps × duration`.

**Cause:** The video is variable frame rate (VFR), or the nominal fps
is slightly off from the actual (e.g. 29.97 NTSC instead of 30).

**Fix:**
```bash
ffprobe data/videos/clip_042.mp4 2>&1 | grep fps
```

If it reports `29.97 fps` or `29.97 tbr`, that's normal. `t_ms` in the
JSONL uses the actual fps from OpenCV, so the timing is still correct.
Just update `fps` in `videos.csv` to match (OK to round to the integer —
`t_ms` is recomputed from the actual frame index, not from the
videos.csv value).

If the video is genuinely VFR (unusual — some screen recorders do this),
re-encode to constant fps:
```bash
ffmpeg -i clip_042.mp4 -vsync cfr -r 30 clip_042_cfr.mp4
```

### B3. MediaPipe detected a person but all landmarks are `(0, 0)`

**Symptom:** JSONL rows with 33 landmarks but `x=0, y=0, z=0` for all.

**Cause:** Rare, but happens when MediaPipe's confidence is low enough
that it detects a person but tracks them at the origin — effectively
a detection failure.

**Fix:** No code-level fix needed. The `confidence` (`v`) field on
these landmarks will be near-zero, so downstream code (via
`landmark(index, min_confidence=0.5)`) treats them as missing. If
missing-person ratio > 10%, address the upstream cause (lighting,
framing) — see [`07_recording_guide.md`](07_recording_guide.md).

### B4. "Extracting clip_042.mp4" prints but JSONL is empty

**Symptom:** Script exits 0, but `data/keypoints/clip_042.jsonl` is
0 bytes or has zero lines.

**Cause:** OpenCV couldn't read the video file (wrong codec, corrupted
file, DRM).

**Fix:**
```bash
# Sanity-check the video
ffprobe data/videos/clip_042.mp4

# If ffprobe errors, the file is broken. Re-export from source.
# If ffprobe works but OpenCV doesn't, the codec isn't supported by
# your OpenCV build. Re-encode:
ffmpeg -i clip_042.mp4 -c:v libx264 -crf 18 -c:a copy clip_042_h264.mp4
```

---

## Phase C — Per-rep stats

### C1. `KeyError: 'clip_042'` when running `compute_rep_stats.py`

**Symptom:**
```
KeyError: 'clip_042'
```

**Cause:** `reps.csv` has a row for `clip_042` but `videos.csv` doesn't,
or the keypoints JSONL doesn't exist. The script needs both.

**Fix:** Check all three:
```bash
grep clip_042 data/annotations/videos.csv       # must exist
grep clip_042 data/annotations/reps.csv         # must exist
ls data/keypoints/clip_042.jsonl                # must exist
```

If any is missing, fix the missing side. A typo in `clip_id` (e.g. a
trailing space) is the most common cause — the CSV reader strips
whitespace but different case matters (it lowercases `quality` and
`view`/`side`/`arm` but leaves `clip_id` as-is).

### C2. Derived stats have lots of `None` angles

**Symptom:** `per_rep_stats.csv` has many blank `start_angle` /
`peak_angle` / `end_angle` cells.

**Cause:** MediaPipe didn't track the arm landmarks well at those
specific frames — likely occlusion, bad framing, or confidence below
threshold.

**Fix:**
1. Open the notebook and plot the angle trace for the affected clip.
   Is the landmark confidence systematically low on one arm?
2. If yes, re-record with better framing.
3. If no (one-off bad frame), leave the None values — the rep is still
   useful if most frames are valid. `valid_frame_ratio` should be > 0.7
   for the rep to count for percentile math.

### C3. `compute_rep_stats` succeeds but Phase D can't find good reps

**Symptom:**
```
derive_thresholds.py: error: fewer than 5 good reps, got 0
```

**Cause:** The `quality` column in `reps.csv` doesn't match any of the
expected values exactly. Typos like `Good`, `goood`, `good ` (trailing
space) — the reader lowercases and strips, but check for typos.

**Fix:**
```bash
# See what quality values actually appear:
awk -F, 'NR > 1 {print $6}' data/annotations/reps.csv | sort -u
```

Should show `good`, `bad_swing`, `bad_partial_rom`, `bad_speed`. Fix
typos and re-run.

---

## Phase D — Derive thresholds

### D1. Script exits with "Invariant violation: start ≤ peak_exit"

**Symptom:**
```
InvariantError: curl_start_angle (155.7°) must be greater than curl_peak_exit_angle (170.3°)
```

**Cause:** The derived `peak + 15° gap` exceeds the derived `start`.
This happens when the dataset has shallow-peaks reps (peak_angle close
to 155°) and steep-start reps (start_angle ≤ 170°).

**Fix:**
1. **First, check the data.** Is one subject's peak angle dragging the
   P75 up? The notebook's per-subject plot will show it.
2. If yes, either record more data from other subjects, or exclude the
   outlier reps from `reps.csv` (set `quality` to `bad_partial_rom` if
   they genuinely aren't hitting peak).
3. If the data is correct and the invariant still fails, the dataset
   is genuinely pathological — consider reducing `CURL_PEAK_EXIT_GAP_DEG`
   in `derive_thresholds.py`. But understand the trade-off: a smaller
   gap means the FSM might oscillate between PEAK and CONCENTRIC near
   peak flexion.

### D2. CIs are very wide (>15°)

**Symptom:** `ci_high_deg - ci_low_deg > 15` for some threshold.

**Cause:** Too little data (bootstrap CI shrinks as √n), or very
heterogeneous data (different subjects with very different form).

**Fix:**
- Record more clips with more subjects.
- Rerun the notebook per-subject breakdown to see if one subject is an
  outlier. If so, consider whether their data should be included (if
  they represent a valid user population, yes; if they're a beginner
  with wildly off form, maybe not).

### D3. `generate_dart.py` produces diff with no data change

**Symptom:** You didn't change the data, but re-running Phase D
produces a different `default_rom_thresholds.dart`.

**Cause:** Non-determinism somewhere. The bootstrap is seeded
(`seed=1234` in `derive_thresholds.py`), so this shouldn't happen. If
it does:

1. Check the seed: `grep BOOTSTRAP_SEED scripts/derive_thresholds.py`.
   Should be `1234`.
2. Check the data: `git diff data/derived/per_rep_stats.csv` — is it
   genuinely unchanged?
3. If the data truly hasn't changed and the output differs,
   **file a bug** — the determinism contract is broken and the test
   suite missed it.

---

## Phase E — Replay

### E1. `flutter analyze` reports 12 `uri_does_not_exist` errors

**Symptom:**
```
error • Target of URI doesn't exist: 'package:fitrack/engine/rep_counter.dart'
```

**Cause:** `flutter pub get` hasn't been run inside `dart_replay/`
yet, so the `path:` dep isn't resolved.

**Fix:**
```bash
cd tools/dataset_analysis/dart_replay
flutter pub get
flutter analyze   # should now be clean
```

For running `flutter analyze` at the repo root without the errors,
`dart_replay/analysis_options.yaml` excludes `bin/**`. If you delete
that file, the errors come back. See
[`04_phase_E_replay.md §6`](04_phase_E_replay.md#6-the-analysis_optionsyaml-rationale).

### E2. Replay F1 drops after a threshold change

**Symptom:** Previous F1 was 0.98, now 0.89 after changing
`SAFETY_MARGIN_DEG`.

**Cause:** Expected — that's what validation is for. The new thresholds
break rep counting for some clips.

**Fix:**
1. Open `validation_report.md` and find the clip(s) with the biggest
   F1 drop.
2. Watch those clips alongside the detected vs annotated rep timings.
3. Determine whether:
   - The new thresholds are too strict (missing reps) — loosen them or
     the margin.
   - The new thresholds are too permissive (phantom reps) — tighten.
   - The annotations are wrong — fix `reps.csv`.
4. Iterate until F1 ≥ 0.95 overall, no clip < 0.85.

**Do not** force through a bad F1. That's how regressions ship.

### E3. Replay report shows 0 TP on a clip that clearly has reps

**Symptom:** A clip has annotations in `reps.csv` but the report says
`TP=0, FP=0, FN=10`.

**Cause:** The FSM isn't firing at all on that clip. Likely:
- The `arm` column in `videos.csv` is wrong (e.g. says `right` but the
  JSONL only has left-arm landmarks tracked well).
- The JSONL is empty or has all missing-person rows.
- The thresholds are catastrophically wrong (e.g. `start < peak`).

**Fix:** Sanity-check the inputs:
```bash
# JSONL not empty?
wc -l data/keypoints/clip_042.jsonl

# Missing-person ratio low?
grep -c '"landmarks":\[\]' data/keypoints/clip_042.jsonl

# arm column correct?
grep clip_042 data/annotations/videos.csv
```

If all looks OK, run the notebook and plot the angle trace for that
clip. If the trace doesn't dip between ~150° and ~70°, the clip isn't
usable — re-record or drop it.

---

## General

### G1. Tests pass locally but fail on a colleague's machine

**Cause:** Probably environment drift — different Python, different
numpy version, or an unseeded random source we missed.

**Fix:**
```bash
# Compare Python:
python3 --version

# Compare pip freeze:
pip freeze > my_env.txt
# Colleague runs the same, diff the files.
```

The pinned versions in `requirements.txt` should produce identical
behaviour. If they don't, the test is non-deterministic — find the RNG
call missing a seed.

### G2. "I changed something and now the pipeline is in a weird state"

**Fix:** Clean rebuild as described in
[`02_pipeline_runbook.md §8`](02_pipeline_runbook.md#8-clean-rebuild):

```bash
cd tools/dataset_analysis
rm -rf data/derived/*
find . -type d -name __pycache__ -exec rm -rf {} +
python scripts/compute_rep_stats.py
python scripts/derive_thresholds.py
python scripts/generate_dart.py
cd dart_replay && dart run bin/replay.dart
```

All outputs are deterministic given the same inputs, so a clean rebuild
is always safe and will expose any lingering cache-induced weirdness.

### G3. Nothing works and I'm panicking

**Breathe.** The pipeline is designed so every output file can be
regenerated from committed inputs. The only irreplaceable things are:

1. The original video files in `data/videos/` (git-ignored — your
   local backup is the only copy).
2. The annotations in `data/annotations/*.csv` (committed).

If you have those, you can rebuild everything else. Start by running
the clean rebuild from G2. If that doesn't work, bisect: comment out
phases of the pipeline and run them one at a time until you find the
stuck step.
