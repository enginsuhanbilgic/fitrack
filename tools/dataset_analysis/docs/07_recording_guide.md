# Recording Guide — How to Capture Usable Clips

> The thresholds you ship are only as good as the reps you labelled.
> The reps you labelled are only as good as the videos you recorded.
> This guide is the practical checklist for getting videos that produce
> clean MediaPipe output and ground-truth-able reps.

---

## 1. Equipment

### 1.1 Camera

Any phone with video at ≥30 fps is fine. Rear camera preferred (higher
resolution, better auto-focus). A modern mid-range Android or iPhone
(2020+) is more than enough.

**Don't use:**
- Wide-angle / ultra-wide lenses. They distort joint positions at the
  edges of the frame and MediaPipe gets confused.
- Action cameras with fisheye correction disabled.
- Anything recording below 720p.

### 1.2 Tripod or fixed mount

**Mandatory.** Hand-held footage introduces global motion that
corrupts the landmark stream — MediaPipe spends half its compute
correcting for camera shake instead of tracking the user. A cheap phone
tripod ($15) is a better investment than any other piece of gear.

If a tripod isn't available, prop the phone against a stable object
(wall, box, shelf) at the right height. Do not hold it.

### 1.3 Lighting

- **Front-lit is best.** Subject faces the light, shadows fall behind
  them.
- **Avoid backlighting.** A bright window behind the subject turns them
  into a silhouette. MediaPipe can still detect a silhouette, but
  confidence scores drop and the landmarks jitter.
- **Avoid mixed lighting.** Half-lit subjects (one side in shadow) cause
  asymmetric confidence — the lit arm tracks well, the shadowed arm
  doesn't. Bad for side-view clips where one side is the one we need.
- **Indoors under normal room lighting is usually fine.** You don't
  need studio gear.

---

## 2. Framing

### 2.1 Camera placement

Two supported views:

| View | Camera position | What's visible |
|---|---|---|
| `side` | Perpendicular to subject's sagittal plane | One full side (shoulder, elbow, wrist, hip, knee) |
| `front` | Facing subject head-on | Both arms, torso, head |

Both views are valid inputs — `videos.csv` records which one, and
`compute_rep_stats` doesn't treat them differently (it uses the same
elbow-angle math either way). The `view` column exists so the notebook
can break down distributions per-view and spot systematic differences.

**Side view** is generally cleaner for biceps curls because:
- One arm is fully visible without self-occlusion.
- The elbow joint is in profile, which MediaPipe tracks accurately.
- Shoulder drift and wrist swing are easier to see.

**Front view** works too but introduces self-occlusion when the arm is
at peak flexion — the hand occludes the shoulder. MediaPipe handles it,
but landmark confidence drops in the peak region.

### 2.2 Distance

- Subject's **full body should fit** in the frame with ~10% padding top
  and bottom. If the subject is cut off at the knees or head, MediaPipe
  can still detect the visible landmarks, but the torso_length
  computation becomes unreliable (shoulder-mid to hip-mid distance is a
  normaliser used in shoulder_drift_norm / wrist_swing_norm).
- **Typical distance:** 2–3 meters from the camera for a standing adult.
- **Don't zoom in on the arm.** Shoulder and hip must both be visible
  for the normaliser to work.

### 2.3 Camera height

- **Chest height, pointed level.** Not from the floor up, not from above.
- A camera looking up or down compresses one axis and throws off the
  angle computation. MediaPipe's `z` coordinate is especially noisy off
  the horizontal plane.

---

## 3. The subject (you, or whoever)

### 3.1 Clothing

- **Fitted clothing beats baggy.** A loose hoodie hides the shoulder
  and elbow landmarks — MediaPipe guesses, and it guesses wrong more
  often than it guesses right.
- **Short sleeves or tight long sleeves** for upper-body exercises.
- **Avoid all-black clothing on a dark background.** The detector uses
  silhouette cues and can fail to separate subject from background.
  High-contrast clothing against the wall is ideal.

### 3.2 Body position

- **Face the camera (front view) or stand perpendicular (side view).**
  No angled poses.
- **Feet shoulder-width, stable stance.** No shifting weight between
  reps (adds noise to hip/shoulder tracking).
- **Upper arm against the torso for biceps curls** unless you're
  deliberately recording bad-form samples.

### 3.3 Reps per clip

- **8–12 reps per clip.** Enough to get a few data points without
  creating annotation fatigue.
- Start the video **before** beginning the first rep (you want the rest
  frame captured). Stop the video **after** the last rep returns to
  rest.
- **Pause between reps** noticeably — 1–2 seconds of clearly-at-rest
  at the top and bottom. Makes annotation much easier.

### 3.4 Mixing rep quality (optional)

If you want the dataset to include `bad_swing`, `bad_partial_rom`, and
`bad_speed` examples:

- Do separate clips for each bad-form type. Don't mix within a single
  clip — it's confusing to annotate and the FSM would see very
  heterogeneous behaviour.
- Label the clip's `notes` column clearly:
  `notes: deliberately bad_swing reps for calibration`.
- Remember: only `good` reps feed Phase D percentile math. Bad reps
  still matter for Phase E F1 scoring (the FSM should count them just
  like good ones).

---

## 4. File naming convention

```
clip_{nnn}_{subject_id}_{view}_{side}.mp4
```

| Component | Format | Example |
|---|---|---|
| `nnn` | zero-padded 3-digit index | `042` |
| `subject_id` | short alphanumeric, underscore-separated | `subj_a`, `subj_b1` |
| `view` | `front` or `side` | `side` |
| `side` | `left`, `right`, or `both` | `right` |

Full example: `clip_042_subj_a_side_right.mp4`

This becomes the `clip_id` throughout the pipeline:
- `data/keypoints/clip_042_subj_a_side_right.jsonl`
- `data/annotations/videos.csv` row with `clip_id = clip_042_subj_a_side_right`
- `data/annotations/reps.csv` rows with the same `clip_id`

**Stick to the convention.** The notebook's per-subject and per-view
grouping relies on parsing the filename, and ad-hoc names break the
grouping.

---

## 5. Pre-record checklist

Before hitting record:

- [ ] Tripod set, camera level at chest height
- [ ] Subject positioned 2–3m away, framed head-to-feet
- [ ] Lighting: subject front-lit, no backlight
- [ ] Clothing: fitted, contrasts with background
- [ ] Phone in landscape orientation (not portrait — gives more
      horizontal room for side views)
- [ ] Video at 30 fps, 720p or higher
- [ ] A clear rest frame at the start (subject standing, arms down, not
      yet moving)

---

## 6. Post-record checklist

After saving the clip:

- [ ] Rename the file to the naming convention immediately. Don't leave
      it as `IMG_4821.mov` — you'll never untangle it.
- [ ] Move into `data/videos/` (git-ignored, so no risk of committing).
- [ ] Log subject + notes in your annotation spreadsheet before moving
      on to the next clip (you'll forget details between clips).
- [ ] Spot-check the video: open it, verify the subject is in frame for
      the whole duration, verify no unexpected camera shake.

---

## 7. Batch recording tips

When doing a session with multiple clips:

- **Same setup for the whole session.** Don't move the camera between
  clips unless you're deliberately changing view/side. Consistent setup
  reduces per-clip noise.
- **Record a short "calibration" clip first.** 5 seconds of the subject
  standing still. Extract keypoints on it and make sure MediaPipe is
  happy (no missing-person frames, confidence > 0.9 on major joints)
  before committing to a long session.
- **Take breaks.** Tired subjects produce noisier form. If the session
  runs over 20 minutes, split it across sessions.

---

## 8. When to re-record

Re-record if:

- MediaPipe missing-person ratio > 10% for the clip (see
  [`03_phase_B_extraction.md §5.1`](03_phase_B_extraction.md#51-sanity-checks)).
- Elbow angle trace in the notebook has obvious flat spots or crazy
  spikes — the landmarks are bad and the rep stats will reflect that.
- Subject walks in or out of frame during reps.
- The whole clip is under-lit or back-lit.

**Don't re-record if:**

- One or two reps look off. Just mark them `bad_partial_rom` or
  similar — that's what the quality labels are for. The percentile
  math handles messy data; you only need a pristine clip when MediaPipe
  itself is failing.
- The subject made a mistake mid-rep. Annotate it as the appropriate
  bad-form label, or skip that rep entirely by leaving it out of
  `reps.csv`.

---

## 9. Ethical / privacy considerations

- **Don't commit videos to git.** They're in `.gitignore` for a reason:
  videos are PII. If `data/videos/` accidentally gets committed, rotate
  the commit history (`git filter-repo`) immediately.
- **Get consent from subjects.** Especially if videos leave your
  personal machine (shared to collaborators, backed up to cloud, etc.).
- **Faces can be blurred in post** if the subject is identifiable and
  you need to share clips externally. MediaPipe doesn't care about
  faces — it uses body landmarks. Blurring the face region doesn't
  affect pose estimation.
