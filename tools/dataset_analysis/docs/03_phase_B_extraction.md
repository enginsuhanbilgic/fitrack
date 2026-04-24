# Phase B — Video Extraction + Annotation Workflow

> Covers `scripts/extract_keypoints.py` in detail (what it does, what it
> doesn't, how to interpret the JSONL output), and the manual annotation
> workflow that follows. This is the phase where the data *actually*
> exists; everything downstream is arithmetic on this output.

---

## 1. What `extract_keypoints.py` does

Reads a video frame-by-frame with OpenCV, runs MediaPipe Pose Landmarker
on each frame, and writes one JSON object per line to
`data/keypoints/{clip_id}.jsonl`.

### 1.1 Output schema

```json
{
  "frame": 42,
  "t_ms": 1400,
  "landmarks": [
    {"x": 0.51, "y": 0.32, "z": -0.10, "v": 0.98},
    ... 33 landmarks, ordered by BlazePose index 0..32 ...
  ]
}
```

- `frame` — 0-based video frame index.
- `t_ms` — `round(frame * 1000 / fps)`. Integer milliseconds since the
  start of the clip.
- `landmarks` — always 33 entries when a person is detected; an empty
  list `[]` when MediaPipe didn't find a person in that frame.
- Each landmark: `x`, `y` normalised to `[0, 1]` (relative to frame
  dimensions), `z` roughly in the same scale as `x` (depth relative to
  hip midpoint), `v` = visibility in `[0, 1]`. We rename MediaPipe's
  `visibility` → `v` to match the on-device naming convention.

All floats are rounded to 6 decimals (~mm precision at normalised
scale). This keeps the JSONL files smaller without losing useful
information.

### 1.2 MediaPipe configuration

```python
mp.solutions.pose.Pose(
    static_image_mode=False,       # use temporal tracking
    model_complexity=2,            # Heavy — highest accuracy
    enable_segmentation=False,     # we only need landmarks
    smooth_landmarks=False,        # smoothing happens downstream
    min_detection_confidence=0.5,
    min_tracking_confidence=0.5,
)
```

**Why each knob is set this way:** see
[`01_architecture_and_rationale.md` §2.2](01_architecture_and_rationale.md#22-phase-b--video--keypoints-jsonl).
The short version: this config is the best approximation of "what the
on-device app would see if it had infinite compute and ran the Heavy
model." Smoothing is off because the shipping FSM applies its own
3-frame MA downstream — we avoid double-smoothing.

### 1.3 The "missing person" case

If MediaPipe fails to detect a person in a frame (occlusion, off-screen,
first/last frames where the user is walking into/out of frame), the
output row is:

```json
{"frame": 42, "t_ms": 1400, "landmarks": []}
```

Downstream code treats `[]` the same as "all landmarks below confidence"
— the frame is skipped for angle/statistic computation, but the rep
window counts it toward `valid_frame_ratio`.

---

## 2. Running extraction

### 2.1 Single clip

```bash
python scripts/extract_keypoints.py --video data/videos/clip_042.mp4
```

Output defaults to `data/keypoints/clip_042.jsonl`. Override with
`--out`.

### 2.2 Batch mode

```bash
python scripts/extract_keypoints.py --all
```

Processes every file in `data/videos/` with a known extension
(`.mp4`, `.mov`, `.m4v`, `.avi`). Skips clips whose JSONL is newer than
the video (the `is_stale` check).

### 2.3 Model complexity override

```bash
python scripts/extract_keypoints.py --video data/videos/clip_042.mp4 --model-complexity 1
```

- `--model-complexity 0` — Lite. Faster, less accurate. Don't use for
  threshold derivation.
- `--model-complexity 1` — Full. Middle ground. Only use if Heavy fails
  to load (rare).
- `--model-complexity 2` — **Heavy. Default. Use this.**

### 2.4 Progress output

The script prints to stderr every 60 frames:

```
Extracting clip_042.mp4 -> clip_042.jsonl
  clip_042.mp4: 60 frames (23.4 fps avg)
  clip_042.mp4: 120 frames (24.1 fps avg)
  ...
  done: 900 frames
```

The `fps avg` is the processing rate, not the video fps. On an M-series
Mac with Heavy model, expect ~15–30 fps processing speed — so a
30-second clip at 30 fps (= 900 frames) takes ~30–60 seconds.

---

## 3. Annotation

This is the part no automation can do for you — it requires a human
watching the videos and writing down where reps begin and end.

### 3.1 videos.csv — one row per clip

```csv
clip_id,subject_id,view,side,arm,fps,notes
clip_042,subj_a,side,right,right,30,good lighting indoors
clip_043,subj_a,front,both,both,30,slight wrist rotation
```

| Column | Values | Meaning |
|---|---|---|
| `clip_id` | matches filename stem | joins to keypoints and reps |
| `subject_id` | `subj_a`, `subj_b`, ... | used for "no single subject dominates" check |
| `view` | `front` \| `side` | camera angle |
| `side` | `left` \| `right` \| `both` | which side of the body is visible (side view → one side) |
| `arm` | `left` \| `right` \| `both` | which arm is working |
| `fps` | integer | video's frame rate |
| `notes` | free text | anything relevant — lighting, form quirks, clothing |

The `arm` column controls how `compute_rep_stats` picks the elbow-angle
signal: `left`/`right` uses that side's triplet; `both` averages left
and right when both have valid landmarks, falls back to whichever side
is valid. This matches `rep_counter.dart._computeAngle` exactly.

### 3.2 reps.csv — one row per rep

```csv
clip_id,rep_idx,start_frame,peak_frame,end_frame,quality
clip_042,1,15,47,78,good
clip_042,2,92,125,156,good
clip_042,3,170,199,228,bad_partial_rom
```

| Column | Meaning |
|---|---|
| `clip_id` | must exist in `videos.csv` |
| `rep_idx` | 1-based, per clip. Restart at 1 for each clip. |
| `start_frame` | frame where the user begins the concentric phase (arm straight, about to flex) |
| `peak_frame` | frame of maximum flexion (elbow angle at its minimum) |
| `end_frame` | frame where the user has returned to rest (arm straight again, ready for the next rep) |
| `quality` | `good`, `bad_swing`, `bad_partial_rom`, `bad_speed` |

**How to pick the frames:**

1. Open the video in a player that shows frame numbers (VLC with the
   frame-step plugin, QuickTime with `F` for frame step, or a video
   editor like DaVinci Resolve).
2. Step forward until you see the arm clearly begin to flex. That's
   `start_frame`.
3. Step forward until the arm is maximally bent. That's `peak_frame`.
4. Step forward until the arm is back to fully extended and *not yet*
   starting the next rep. That's `end_frame`.
5. Judge the rep quality:
   - **`good`** — clean form, full ROM, steady tempo.
   - **`bad_swing`** — visible torso or elbow body-English to cheat the
     rep up. Typical in heavy-weight sessions.
   - **`bad_partial_rom`** — stopped short. Either doesn't reach the
     peak or doesn't fully extend at the end.
   - **`bad_speed`** — eccentric (down phase) too fast. "Dropping" the
     weight rather than controlling it.

**Edge cases:**

- **First rep doesn't start from rest.** If the video starts with the
  arm mid-rep, skip the first rep. Start `rep_idx=1` from the first
  rep that has a clean start frame.
- **Reps blend together.** If the user doesn't fully extend between
  reps, pick the minimum-angle frame between them as the boundary
  (= `end_frame` of rep N, `start_frame` of rep N+1). Label the rep as
  `bad_partial_rom`.
- **Rep fails mid-way.** If the user aborts a rep (e.g. drops the
  dumbbell halfway up), don't annotate it.

### 3.3 Annotation hygiene

- **Two-pass review.** Annotate once, watch the video again, verify.
  Off-by-one frames on `start_frame` can shift `start_angle` by 5–10°,
  which propagates directly into the derived threshold.
- **Consistency across annotators.** If multiple people are labelling,
  agree on the rep-quality criteria before starting. An inter-rater
  spreadsheet pass on the first N reps (everyone labels the same reps
  blind, then compares) is well spent.
- **Don't fix the annotation to match the FSM.** The annotations are
  ground truth; the FSM is what we validate against the ground truth.
  If the FSM counts a rep you labelled `bad_partial_rom`, that's a
  false positive to track, not a labelling error.

---

## 4. The JSONL → FrameSample adapter

Python code that consumes the JSONL goes through `scripts/jsonl_io.py`:

```python
from scripts.jsonl_io import load_frames, FrameSample

frames: list[FrameSample] = load_frames(Path("data/keypoints/clip_042.jsonl"))
for f in frames:
    elbow = f.landmark(13)  # LEFT_ELBOW
    if elbow is not None:
        print(f.frame, elbow.x, elbow.y, elbow.confidence)
```

`FrameSample` is the canonical in-memory representation:

```python
@dataclass(frozen=True)
class FrameSample:
    frame: int
    t_ms: int
    landmarks: list[Optional[Landmark]]  # length 33, None for missing

    def landmark(self, index: int) -> Optional[Landmark]:
        ...
```

`_decode_landmarks` validates that each row has exactly 33 landmarks
(or zero, for missing-person frames) and raises loudly otherwise. Any
corrupted JSONL will fail fast rather than silently producing bad
percentiles.

---

## 5. Verifying extraction worked

### 5.1 Sanity checks

```bash
# How many frames?
wc -l data/keypoints/clip_042.jsonl

# Any rows with missing people?
grep -c '"landmarks":\[\]' data/keypoints/clip_042.jsonl
```

Expect:
- Frame count ≈ `fps × video_duration_seconds`.
- Missing-person ratio < 10% for a well-lit, well-framed video. If it's
  higher, the video probably has the user walking in/out of frame — trim
  the clip or tolerate it (the annotation can simply exclude those reps).

### 5.2 Visual verification (optional, high-value)

Open the notebook and load a single clip's frames:

```python
frames = load_frames(Path("data/keypoints/clip_042.jsonl"))
angles = [elbow_angle_for_arm(f, "right") for f in frames]
plt.plot([f.t_ms for f in frames], angles)
```

A good clip's elbow angle looks like a sequence of valleys (one per rep)
between ~165° (rest) and ~60° (peak). If the trace is noisy or doesn't
dip, either the user's arm was off-screen or the camera angle is wrong.

---

## 6. What NOT to do

- **Don't hand-edit JSONL files.** They're regenerated from video. If
  you need to correct bad MediaPipe output, fix the *input* (trim the
  video) and re-extract.
- **Don't commit videos or JSONL to git.** Both are in `.gitignore`
  for a reason: videos are large and sometimes PII, JSONL is
  reproducible from the video.
- **Don't use the Lite model for threshold derivation.** It's noisier
  and will shift your percentiles in unpredictable directions.
- **Don't extract the same video twice concurrently.** The output file
  will be corrupted. The script doesn't lock.

---

## 7. Common pitfalls

**"My `fps avg` is 2 fps — is something wrong?"**
Probably CPU-only inference. Check that `mediapipe` can see a GPU
(on macOS it uses Metal via the Apple frameworks automatically; on
Linux you may need the CUDA build). The pipeline still works at 2 fps,
it just takes longer.

**"The JSONL has 1000 frames but the video is 30 seconds at 30 fps."**
Check the video's actual fps: `ffprobe data/videos/clip_042.mp4 | grep fps`.
Some phone cameras record at 29.97 fps (NTSC) and some clips are
variable frame rate — OpenCV usually reads them fine, but the frame
count can differ slightly from the nominal duration.

**"MediaPipe detected a person but the landmarks are all (0, 0)."**
Rare but happens near the frame edges. It means the person is detected
but tracked at the origin — effectively a detection failure. Treat
those frames as missing-person for analysis purposes; they'll fail the
confidence gate downstream anyway.
