# Annotations

Ground truth that ties each recorded clip to one or more rep boundaries. One
row per clip in `videos.csv`, one row per rep in `reps.csv`.

## Two workflows — pick one per clip

### A. Auto-annotate from a clip-level quality label (recommended)

Shoot a clip where every rep has the **same** quality (all-good, all-swing,
all-partial-ROM, all-speed). Then:

1. Add a single row to `videos.csv` including `intended_quality` (one of
   `good` / `bad_swing` / `bad_partial_rom` / `bad_speed`).
2. Run Phase A to extract keypoints:
   ```bash
   python scripts/extract_keypoints.py
   ```
3. Run Phase B auto-annotation to emit `reps.csv`:
   ```bash
   python scripts/phase_b_auto_annotate.py --review
   ```
   The script walks the smoothed elbow-angle series and emits
   `(start_frame, peak_frame, end_frame)` triples at every rest → peak → rest
   cycle that passes the 40° excursion gate and 8-frame dwell gate (mirrors
   the shipping Dart `rep_boundary_detector`). The per-rep `quality` column
   is inherited from `videos.intended_quality`.
4. Sanity-check the `--review` summary (printed to stderr): if the detected
   count is off by more than a rep or two for a clip, spot-check that clip
   manually.

### B. Hand-annotated frame boundaries (fallback)

Use this when a single clip mixes rep qualities, when the pose extractor
missed too many frames, or when you want to lock in ground truth for a
replay-validation clip.

1. Open the raw video in VLC.
2. Scrub frame-by-frame (`E` key in VLC) to find rep boundaries.
3. Record the frame index (VLC's `Tools → Media Information → Codec` shows
   frame).
4. Write `videos.csv` **without** `intended_quality` (or leave it blank) and
   fill `reps.csv` rows by hand.

Hand-written `reps.csv` rows are never overwritten by the auto-annotator —
Phase B writes a separate `reps.csv`, so keep a backup or point the script
at `--out custom_path.csv` if you want to preserve hand edits.

## `videos.csv` schema

```csv
clip_id,subject_id,view,side,arm,fps,intended_quality,notes
clip_001,alihan,side,right,right,30,good,"dumbbell, clean form"
clip_005,alihan,front,both,both,30,bad_swing,"intentional torso English"
```

| Column | Type | Values |
|---|---|---|
| `clip_id` | str | Matches video filename stem |
| `subject_id` | str | Stable pseudonym across this subject's clips |
| `view` | enum | `front` \| `side` |
| `side` | enum | `left` \| `right` \| `both` |
| `arm` | enum | Which arm is the working arm: `left` \| `right` \| `both` |
| `fps` | int | Video frame rate (usually 30) |
| `intended_quality` | enum (optional) | `good` \| `bad_swing` \| `bad_partial_rom` \| `bad_speed`. Blank = hand-annotate per rep. |
| `notes` | str | Free text — equipment, form notes, camera setup |

## `reps.csv` schema

```csv
clip_id,rep_idx,start_frame,peak_frame,end_frame,quality
clip_001,0,15,47,82,good
clip_001,1,85,119,156,good
clip_001,2,160,198,240,bad_swing
```

| Column | Type | Values |
|---|---|---|
| `clip_id` | str | Foreign key → `videos.csv` |
| `rep_idx` | int | 0-indexed within the clip |
| `start_frame` | int | Arm fully extended at bottom |
| `peak_frame` | int | Arm maximally flexed at top |
| `end_frame` | int | Arm returned to extension |
| `quality` | enum | `good` \| `bad_swing` \| `bad_partial_rom` \| `bad_speed` |

## Quality labels

- **`good`** — clean rep. Used for percentile derivation.
- **`bad_swing`** — body English / torso swing. Used for swing-threshold derivation.
- **`bad_partial_rom`** — didn't reach full flexion or extension. Used for FSM false-negative check.
- **`bad_speed`** — too fast or too slow. Used for tempo threshold derivation.

**Bad reps are not thrown away** — they feed the false-positive side of the
Dart replay validation in `dart_replay/bin/replay.dart`.

## Why clip-level quality, not per-rep quality?

The auto-annotator detects rep **frames** from the signal (local extrema
gated by minimum excursion and dwell), which is reliable. But judging rep
**quality** requires visual inspection of body English, tempo, depth — all
of which a human has to label. Rather than asking the annotator to label
every rep after the script emits boundaries, we flip the workflow: record
clips that are quality-homogeneous by construction, label the clip once,
and inherit. This is faster and catches the dataset design error (*"oh,
rep 7 was a bad one and the rest were good"*) at recording time instead of
labelling time.
