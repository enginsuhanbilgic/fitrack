# Phase D — Threshold Math Deep-Dive

> The `scripts/derive_thresholds.py` step is where empirical data gets
> turned into four numbers that ship to every user's phone. This file
> explains *why* each choice (percentile, margin, bootstrap config,
> invariants) is what it is, and what the alternatives would have cost.

---

## 1. The four thresholds we derive

From `app/lib/engine/rep_counter.dart`, the FSM needs:

| Constant | Role | FSM transition |
|---|---|---|
| `curlStartAngle` | "arm is straight, rep about to begin" gate | IDLE → CONCENTRIC |
| `curlPeakAngle` | "arm is maximally bent" gate | CONCENTRIC → PEAK |
| `curlPeakExitAngle` | "user is descending from peak" gate | PEAK → ECCENTRIC |
| `curlEndAngle` | "arm is straight again, rep complete" gate | ECCENTRIC → IDLE (rep++) |

Phase D derives the first two directly from the data, computes
`curlPeakExitAngle = curlPeakAngle + 15°`, and derives `curlEndAngle`
directly from the data.

---

## 2. Percentile choices

### 2.1 `curlStartAngle` — P20 of `start_angle`, minus 5° margin

The start gate fires when the user's elbow is **at least this extended**
(angle ≥ threshold). If it's too high, the gate won't open and the rep
won't count. If it's too low, noise in the rest position triggers it.

We pick P20 of `start_angle` across all `good` reps and subtract a 5°
safety margin. Concretely:

- If P20 = 160°, threshold = 155°.
- Interpretation: "80% of good reps started at ≥ 160°. We gate at 155°
  so even the bottom 20% clears it, with 5° of slack for pose noise."

**Why P20 and not P10 or P50?**

- P10 (too permissive): the bottom 10% are typically noisy or the user
  didn't fully extend. Including them as the population we design for
  drags the threshold down, making the gate trip on non-reps.
- P50 (too strict): the median excludes half the good reps by
  construction. A user whose natural rest angle is below median would
  struggle to register reps.
- P20 is the lowest percentile where the "honest bad" tail drops off and
  "real starts" dominate. Empirically validated — see
  [`02_pipeline_runbook.md`](02_pipeline_runbook.md#4-phase-d--derive-thresholds)
  Phase D review step.

### 2.2 `curlPeakAngle` — P75 of `peak_angle`, plus 5° margin

The peak gate fires when the user's elbow is **at least this flexed**
(angle ≤ threshold). Tighter-than-threshold peaks count; looser ones
don't.

We pick P75 and **add** 5° (because the peak angle is a *minimum* —
adding 5° makes the gate more permissive).

- If P75 = 67°, threshold = 72°.
- Interpretation: "75% of good reps peaked at ≤ 67°. We gate at 72° so
  even the top 25% (who don't flex as deeply) still count their reps,
  with 5° of slack."

**Why P75 and not P50 or P90?**

- P50 (median): half of good reps would fail to count. Catastrophic.
- P90 (very permissive): would count half-reps as full reps, since
  shallow flexion would clear the gate.
- P75 is the upper quartile — most good reps pass, but users whose
  natural peak flexion is unusually shallow still count.

### 2.3 `curlPeakExitAngle` — `curlPeakAngle + 15°`

**Not derived from data.** This is a fixed 15° gap above the peak gate.

The peak-exit gate prevents the FSM from oscillating between PEAK and
CONCENTRIC when the user's arm hovers near peak flexion for a moment
(common at the top of a rep). Without a gap, micro-jitter in the angle
signal around the peak threshold would re-enter PEAK repeatedly.

15° is the empirical gap that matches the app's 3-frame MA filter noise
floor. See `app/lib/engine/rep_counter.dart` — the gap is enforced as a
hysteresis pair.

### 2.4 `curlEndAngle` — P20 of `end_angle`, minus 5° margin

Same logic as `curlStartAngle`: 80% of good reps ended at ≥ this angle,
so we gate there with 5° of slack. The rep-end gate must be below the
rep-start gate (invariant `start > end`), which is satisfied by
construction since both use P20 but `end_angle` is typically smaller
than `start_angle` (users rarely return *quite* as straight as they
started from).

---

## 3. The safety margin

`SAFETY_MARGIN_DEG = 5.0` appears four times:

- `curlStartAngle = P20(start_angle) - 5`
- `curlPeakAngle = P75(peak_angle) + 5`
- `curlPeakExitAngle = curlPeakAngle + 15` (separate gap)
- `curlEndAngle = P20(end_angle) - 5`

**Why 5° specifically?**

- Pose estimation is noisy. MediaPipe Heavy on a well-lit side view
  still jitters ±2–3° on the elbow. Over the 3-frame MA window in the
  app, residual noise is ~1–2°.
- User-to-user variation is larger than model noise. A new user whose
  natural rest angle is 3° below the dataset's P20 still clears a 5°
  margin.
- 5° is also small enough that it doesn't compromise the FSM's ability
  to distinguish "real start" from "noise near start." Bigger margins
  (e.g. 10°) would risk the gate opening during random micro-movements.

It's a *single* knob in `derive_thresholds.py` — change
`SAFETY_MARGIN_DEG` and re-run from Phase D. Tests must still pass.

---

## 4. Bootstrap confidence intervals

Each derived threshold ships with a 95% CI computed via **non-parametric
bootstrap**.

### 4.1 What bootstrap gives us

Bootstrap asks: "if we resample the dataset with replacement 1000 times,
how much does the percentile wobble?" The CI is the 2.5th and 97.5th
percentiles of the resampled percentiles.

Example output in `thresholds.json`:

```json
"curl_start_angle": {
  "value_deg": 155.7,
  "ci_low_deg": 152.30,
  "ci_high_deg": 158.90,
  "n": 87,
  "source_percentile": 20,
  "safety_margin_deg": 5.0
}
```

Interpretation: "Our point estimate is 155.7°. With 87 good reps, we're
95% confident the true P20-minus-margin lies between 152.3° and 158.9°."

### 4.2 Why 1000 resamples?

- 100 resamples: CI bounds jitter by ±1° between runs of the script on
  the same data. Unacceptable — we want deterministic output.
- 10,000 resamples: CI stabilises to ~0.05° between runs, but runtime
  grows linearly. For a dataset of ~200 reps, 10k takes ~2 seconds.
- 1000 resamples: CI stable to ~0.3°, runtime <0.2s. The sweet spot.

### 4.3 Why `seed=1234`?

`np.random.default_rng(1234)` makes bootstrap deterministic. Same data
in → byte-identical `thresholds.json` out. This matters because:

- `generate_dart.py` bakes the CI into docstrings in
  `default_rom_thresholds.dart`. Non-deterministic CIs would produce
  spurious diffs on every re-run.
- CI (the continuous integration kind) can check "re-running phase D
  produces the same file" as a regression gate.

The literal `1234` is arbitrary — any fixed seed would work. Picked
for memorability.

### 4.4 What the CI tells you

A CI wider than ~15° is a dataset-size or data-quality warning:

- **Small n.** Bootstrap CIs shrink as √n. If n < 30 reps, expect wide
  CIs — not a bug, just a "you need more data" signal.
- **Heterogeneous data.** If your dataset mixes very different
  subjects/camera angles, the percentile will genuinely be wobbly.
  Split the data and look at per-subject or per-view percentiles in
  the notebook before trusting the aggregate.

The CI is *advisory*. We don't programmatically reject wide-CI
thresholds — that would block the pipeline on any fresh project. But
the PR reviewer should eyeball the CI column and call out anything
suspicious.

---

## 5. FSM invariants

`check_invariants()` enforces four hard constraints on the derived
thresholds. If any fails, `derive_thresholds.py` exits with code `1`
and the pipeline halts.

The invariants come directly from the FSM's state diagram. A violation
means the derived values would produce a FSM that **cannot advance** —
a rep-counter that never counts reps.

### 5.1 `start > peak_exit`

The user goes from IDLE (above `start`) to CONCENTRIC (below `start`) to
PEAK (below `peak`) to ECCENTRIC (above `peak_exit`) to IDLE (above
`end`).

If `peak_exit ≥ start`, the ECCENTRIC state has no "above peak_exit, below
start" region to occupy — it's empty. The FSM can leave PEAK but has
nowhere to go.

### 5.2 `start > end`

The rep-end gate (`end`) must be below the rep-start gate (`start`).
If `end ≥ start`, the ECCENTRIC → IDLE transition would fire before the
user finished the rep (because the ECCENTRIC state requires the angle
to cross *up* through `end`, which is supposed to be above the peak
but below the start — if `end ≥ start`, the IDLE state traps the user
immediately).

### 5.3 `end > peak_exit`

Same reasoning: the ECCENTRIC state lives in `(peak_exit, end)`. If
`end ≤ peak_exit`, that interval is empty or inverted — the user can
never be "in ECCENTRIC".

### 5.4 `peak < start`

The CONCENTRIC state lives in `(peak, start)`. If `peak ≥ start`, it's
empty — the user can never be "in CONCENTRIC", so no rep ever begins.

### 5.5 Why enforce programmatically?

A reviewer reading `thresholds.json` can spot most violations manually.
But:

- Small margins can push a valid threshold set into invariant violation
  after a data update. Catching it in the script is faster than in PR
  review.
- The 5° margin interacts with the percentiles in subtle ways when the
  underlying distributions are unusual (e.g. a dataset where P20 of
  start is very close to P75 of peak).
- Exit code 1 makes the script CI-friendly — a pipeline regression gate
  can `|| exit 1` on the step and fail the build.

---

## 6. What if we wanted to change the math?

The single-knob design means most changes are localised:

- **Different percentile**: edit `START_PERCENTILE`, `PEAK_PERCENTILE`,
  `END_PERCENTILE` constants in `derive_thresholds.py`. Re-run, check
  invariants.
- **Different margin**: edit `SAFETY_MARGIN_DEG`. Same.
- **Different peak-exit gap**: edit `CURL_PEAK_EXIT_GAP_DEG`. Same.
- **Per-subject thresholds**: would require re-architecting — the app
  currently ships *one* set of constants. The notebook's per-subject
  breakdown helps you see whether this would buy much.
- **Switch from percentile to ML model**: much larger change. The
  scripts/tests would need replacement, but the Phase E harness and
  the Dart codegen would keep working unchanged — the interface
  (`thresholds.json`) is stable.

---

## 7. What we're explicitly not doing

- **Hypothesis testing.** No p-values, no "threshold A is significantly
  better than threshold B". We're not inferring population parameters;
  we're picking a gate that works for 80% of the observed data.
- **Bayesian priors.** A previous version's thresholds could be used as
  a prior, but we intentionally don't — the whole point is to derive
  from data, not to pull toward historical guesses.
- **Validation on a held-out split.** With ~200 reps the held-out
  split would have 20–40 reps — too few to be reliable. Phase E
  validates on the same dataset the thresholds were derived from. This
  is a known limitation; generalisation to unseen users is assumed,
  not measured.
