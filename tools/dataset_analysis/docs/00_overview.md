# Dataset Analysis — Overview

> **Read this first.** It explains *why* this tool exists, *what* it
> produces, and *how* the pieces fit together. If you only have five
> minutes, reading this file is enough to orient yourself.

---

## 1. What problem is this solving?

FiTrack's biceps-curl rep counter is driven by a four-state FSM that uses
hard-coded elbow-angle thresholds:

```dart
// app/lib/core/constants.dart
const double kCurlStartAngle   = 160.0;   // IDLE → CONCENTRIC
const double kCurlPeakAngle    = 70.0;    // CONCENTRIC → PEAK
const double kCurlPeakExitAngle = 85.0;   // PEAK → ECCENTRIC (peak + 15° gap)
const double kCurlEndAngle     = 140.0;   // ECCENTRIC → IDLE (rep++)
```

These numbers started as an educated guess based on biomechanics textbooks
and a handful of informal test sessions. They are also the **single most
critical knob** in the whole rep-counter — a bad peak threshold and every
user's reps either under-count (peak threshold too deep) or over-count
(too shallow).

**The question this tool answers:** what would the thresholds be if we
*derived* them from real recorded reps instead of guessing?

The answer has to be:
- **empirical** — grounded in actual pose-estimation data, not intuition
- **defensible** — every number traceable to a percentile on a labelled
  dataset, with a confidence interval so reviewers can see how wobbly the
  estimate is
- **safe** — no derived threshold allowed to ship if it would produce an
  un-enterable FSM
- **reproducible** — anyone running the pipeline on the same input CSVs
  gets bit-identical output

That's this pipeline.

---

## 2. What does the pipeline produce?

One file: `app/lib/core/default_rom_thresholds.dart` — a generated Dart
source file the app imports. Example of what the generator emits:

```dart
// GENERATED FILE — DO NOT EDIT BY HAND.
// Source: tools/dataset_analysis/scripts/generate_dart.py
class DefaultRomThresholds {
  /// Derived at P20 - 5.0° safety margin. 95% CI: [152.30, 158.90].
  static const double curlStartAngle = 155.7;
  /// Derived at P75 + 5.0° safety margin. 95% CI: [69.10, 75.80].
  static const double curlPeakAngle = 72.4;
  // ...
}
```

Everything in this tool — the video extraction, percentile math, bootstrap
CIs, invariant checks, the Dart replay harness — exists to produce this
one file, and to *prove* the values in it don't regress rep-counting
accuracy on a labelled reference dataset.

---

## 3. Pipeline at a glance

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  Phase A    │   │  Phase B    │   │  Phase C    │   │  Phase D    │   │  Phase E    │
│             │   │             │   │             │   │             │   │             │
│  Record     ├──►│  MediaPipe  ├──►│  Per-rep    ├──►│  Derive     ├──►│  Replay     │
│  clips      │   │  extract    │   │  stats      │   │  thresholds │   │  validate   │
│             │   │             │   │             │   │  + Dart gen │   │  F1 report  │
└─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘
     videos        videos + jsonl      per_rep       thresholds.json    validation_
     annotations                      _stats.csv   + default_rom_       report.md
                                                   thresholds.dart
```

| Phase | Input | Output | Scripts |
|-------|-------|--------|---------|
| A | (nothing) | tool skeleton, ported angle math | `scripts/angle_utils.py`, `scripts/landmark_indices.py` |
| B | `data/videos/*.mp4` | `data/keypoints/*.jsonl` | `scripts/extract_keypoints.py` |
| C | keypoints + annotations | `data/derived/per_rep_stats.csv` | `scripts/compute_rep_stats.py` |
| D | per-rep stats | `data/derived/thresholds.json` + generated Dart | `scripts/derive_thresholds.py`, `scripts/generate_dart.py` |
| E | keypoints + annotations | `data/derived/validation_report.md` | `dart_replay/bin/replay.dart` |

Full command-level runbook is in [`02_pipeline_runbook.md`](02_pipeline_runbook.md).

---

## 4. Why this architecture?

Three decisions shaped the code layout; each one was a fork where the other
path would have been *easier* to write and *worse* to maintain.

### 4.1 Why Python for analysis and Dart for replay?

The analysis side (video, percentiles, plots) lives in Python because the
ML/data tooling is mature there — MediaPipe ships a Python solution, pandas
and matplotlib are one pip away, and jupyter notebooks are the lingua
franca for "let me eyeball this distribution."

But the FSM cannot live in Python. The FSM is the single most important
piece of code in the app and it runs in Dart on-device. If we wrote a
Python port for replay:

1. It would start identical to the Dart FSM.
2. Six months later someone fixes a bug in the Dart version.
3. The Python port drifts.
4. The replay harness reports "F1 = 0.98" but the real on-device FSM
   actually scores 0.91, because they are now different FSMs.

**Solution:** the replay harness is a thin Dart binary that imports the
real `RepCounter` via a local `path:` dependency on `../../../app/`. No
Python port of the FSM exists or can exist. The single source of truth
for rep counting is `app/lib/engine/rep_counter.dart`. See
[`04_phase_E_replay.md`](04_phase_E_replay.md) for details.

### 4.2 Why percentiles + safety margins, not ML?

We have at most a few hundred labelled reps. Fitting any non-trivial model
to that much data overfits. The goal also isn't prediction — it's *setting
four thresholds*. Two non-negotiables:

- Every threshold has to be directly explainable: "80% of good reps had
  start_angle > 160°, so we put the gate at 155° with a 5° safety margin."
- Small shifts in the dataset should produce small shifts in the threshold
  (not "we retrained the model and everything moved").

Percentiles + margins satisfy both. See
[`05_phase_D_threshold_math.md`](05_phase_D_threshold_math.md) for why
P20/P75 specifically, why bootstrap CIs, and the invariant checks.

### 4.3 Why hand-annotated reps?

MediaPipe gives us landmark streams. It does *not* tell us where one rep
ends and the next begins, and it certainly doesn't tell us which reps were
"good" vs. "bad swing" vs. "bad partial ROM."

Could we auto-segment with the existing FSM? Yes — but then we'd be
deriving thresholds *from* FSM output, which is circular. Bad reps the FSM
already mis-counts would corrupt the percentile math.

**Solution:** manual annotation of `(start_frame, peak_frame, end_frame,
quality)` per rep, stored in `data/annotations/reps.csv`. The annotation
workflow is in [`03_phase_B_extraction.md`](03_phase_B_extraction.md#annotation).

---

## 5. Trust boundaries

| Boundary | Who wrote the numbers | How we trust them |
|---|---|---|
| `data/videos/*.mp4` | humans recording themselves | n/a — raw input |
| `data/keypoints/*.jsonl` | MediaPipe Heavy model | offline, deterministic per video |
| `data/annotations/*.csv` | humans watching the videos | manual review, two-pass |
| `data/derived/per_rep_stats.csv` | `compute_rep_stats.py` | 32 unit tests on synthetic fixtures |
| `data/derived/thresholds.json` | `derive_thresholds.py` | 20+ unit tests; FSM invariants enforced |
| `app/lib/core/default_rom_thresholds.dart` | `generate_dart.py` | 10+ unit tests; replay F1 must pass |

Every output except the first two comes with a unit test file. See
[`06_testing_and_verification.md`](06_testing_and_verification.md).

---

## 6. Document index

Read in order if you're new:

1. **[00_overview.md](00_overview.md)** — this file
2. **[01_architecture_and_rationale.md](01_architecture_and_rationale.md)** — why every directory exists, why each decision went the way it did
3. **[02_pipeline_runbook.md](02_pipeline_runbook.md)** — command-by-command, copy-paste runbook
4. **[03_phase_B_extraction.md](03_phase_B_extraction.md)** — video → JSONL, annotation workflow
5. **[04_phase_E_replay.md](04_phase_E_replay.md)** — how the Dart replay harness works
6. **[05_phase_D_threshold_math.md](05_phase_D_threshold_math.md)** — percentile / bootstrap / invariant math
7. **[06_testing_and_verification.md](06_testing_and_verification.md)** — test taxonomy, how to add tests
8. **[07_recording_guide.md](07_recording_guide.md)** — how to record good clips (camera angle, lighting, reps/set)
9. **[08_troubleshooting.md](08_troubleshooting.md)** — known failure modes and fixes

Reference: `README.md` at the tool root is the TL;DR; these docs are the
long-form companion.
