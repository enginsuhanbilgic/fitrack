# Testing and Verification

> What the 104 existing tests cover, how they're organised, and how to
> add tests when you change the pipeline. The "verification" part covers
> the non-test gates (analyzer, replay F1, invariant checks) that also
> protect the pipeline.

---

## 1. Test philosophy

Every script in `scripts/` that produces a file consumed by another
script (or by the app) has a test file in `tests/`. The rule is:

> If a bug in this script could silently corrupt downstream output,
> it needs a test.

The flip side: **no integration tests, no fixture videos in the repo**.
We test pure functions on synthetic data. Real video is slow, large,
and can't be committed. The `dart_replay` harness is the only end-to-end
integration test, and it runs on whatever real data the user has
annotated — not on committed fixtures.

---

## 2. Test taxonomy

```
tests/
├── test_angle_utils.py              —  16 tests — Phase A angle math
├── test_landmark_indices.py         —   6 tests — BlazePose index map
├── test_jsonl_io.py                 —  20 tests — JSONL reader + FrameSample
├── test_compute_rep_stats.py        —  32 tests — Phase C per-rep stats
├── test_derive_thresholds.py        —  20 tests — Phase D percentile math
└── test_generate_dart.py            —  10 tests — Phase D Dart codegen
```

Total: **104 tests**. Runtime: ~0.15s on an M-series Mac. Zero external
dependencies (no mediapipe, no cv2) — the scripts guard their heavy
imports, and the tests exercise only the pure-Python subset.

### 2.1 `test_angle_utils.py` — 16 tests

Covers `angle_utils.py`:
- `angle_between_points(a, b, c)` — 3-point angle math in degrees.
  Tests: straight (180°), right-angle (90°), collinear, coincident
  points (returns NaN), numerical robustness at near-zero vectors.
- `elbow_angle_for_arm(frame, arm)` — picks shoulder/elbow/wrist by
  side. Tests: left, right, both (averaging), both with one side
  missing (fallback), all missing (returns None).

### 2.2 `test_landmark_indices.py` — 6 tests

Covers `landmark_indices.py`:
- BlazePose index constants (LEFT_SHOULDER=11, RIGHT_SHOULDER=12, …).
- The `ARM_TRIPLET[side]` dict returning the 3-tuple for elbow
  computation.
- Fail-closed behaviour for invalid side strings.

### 2.3 `test_jsonl_io.py` — 20 tests

Covers `jsonl_io.py`:
- `Landmark` dataclass (`x`, `y`, `z`, `confidence`) — construction,
  immutability, equality.
- `FrameSample.landmark(index)` returns `Optional[Landmark]`.
- `_decode_landmarks()` — accepts length-33 lists, accepts empty list
  (missing person), rejects all other lengths with a clear error.
- `load_frames()` — round-trip with synthetic JSONL, ordering preserved,
  handles trailing newlines, rejects malformed JSON.
- Confidence gating: landmarks below a threshold are returned as None
  by `landmark()` when called with a `min_confidence` argument.

### 2.4 `test_compute_rep_stats.py` — 32 tests

Covers `compute_rep_stats.py`:
- Fixture builders: `_blank_landmarks()`, `_set(...)`, `_straight_arm_right()`,
  `_bent_arm_right()`, `_torso()`, `_sample(...)`.
- `elbow_angle_for_arm` integration tests (on `FrameSample` instead of
  raw dicts).
- `torso_length` = `abs(shoulder_mid_y - hip_mid_y)`, with `None` on
  missing torso landmarks.
- `_median` — odd n, even n, empty list (returns None).
- `compute_rep_stats` on ramp-shaped synthetic frames (angle linearly
  decreases then increases across a window).
- `RepStats.as_csv_row` formatting — None → empty string, floats →
  4-decimal.
- `write_stats_csv` round-trip via `_read_videos_csv` / `_read_reps_csv`
  helpers.
- `iter_rep_stats` skips clips not in `videos.csv` or missing JSONL.
- Whitespace / case normalisation in CSV reads.
- CLI parser defaults.

### 2.5 `test_derive_thresholds.py` — 20 tests

Covers `derive_thresholds.py`:
- `percentile()` — matches numpy "linear" interpolation semantics on
  hand-crafted inputs.
- `bootstrap_ci()` — determinism given seed, correctness on synthetic
  known-CI inputs.
- `StatsRow` CSV parsing, including None-passthrough for blank fields.
- `filter_good` — only `quality == "good"` rows survive.
- `derive_curl_thresholds` end-to-end:
  - Good reps produce expected thresholds.
  - Bad reps are filtered out (verified by comparing against a good-only
    baseline).
  - `n` reflects only good reps.
- `check_invariants`:
  - 1 passing case.
  - 4 failing cases (one per invariant), each asserting
    `InvariantError` is raised with the correct message.
- `write_thresholds_json` — shape, structure, key presence.

### 2.6 `test_generate_dart.py` — 10 tests

Covers `generate_dart.py`:
- `_fake_payload()` helper constructs a valid `thresholds.json` shape.
- BANNER appears in output.
- `static const double curlStartAngle = 155.7;` (1-decimal formatting).
- Dataset summary docstring: `20 good reps / 30 total rows across 2 clip(s)`.
- CI ranges appear in per-constant docstrings.
- `class DefaultRomThresholds` present.
- File written to correct path.
- Missing input JSON → FileNotFoundError.
- Missing `curl` key in JSON → KeyError with message.
- Nested parent directories created automatically.

---

## 3. Running tests

### 3.1 Run everything

```bash
cd tools/dataset_analysis
source .venv/bin/activate   # or install pytest globally
pytest
```

Expected output:

```
============================= 104 passed in 0.14s ==============================
```

### 3.2 Run one file

```bash
pytest tests/test_derive_thresholds.py -v
```

### 3.3 Run one test

```bash
pytest tests/test_derive_thresholds.py::test_check_invariants_rejects_start_not_above_peak_exit -v
```

### 3.4 No extra deps required

`pytest` is the only requirement. Video-processing deps (mediapipe, cv2)
are optional-imported in `extract_keypoints.py` and *never* touched by
the test suite. A fresh clone can run tests with just `pip install pytest`.

---

## 4. Conventions for adding tests

### 4.1 Test naming

```python
def test_<unit>_<condition>_<expected>():
    ...
```

Examples:
- `test_percentile_matches_numpy_on_odd_length_input`
- `test_check_invariants_rejects_end_not_above_peak_exit`
- `test_rep_stats_as_csv_row_formats_floats_and_emits_blank_for_none`

Long names are fine — they're the spec.

### 4.2 Synthetic data, not fixtures

Prefer constructing inputs inline or via small helper functions. Avoid
reading from disk unless the thing under test is an IO function.

```python
# Good
def test_derive_thresholds_filters_bad_reps():
    rows = [
        StatsRow(clip_id="c1", rep_idx=1, quality="good", start_angle=160.0, ...),
        StatsRow(clip_id="c1", rep_idx=2, quality="bad_swing", start_angle=120.0, ...),
    ]
    thresholds = derive_curl_thresholds(rows)
    assert thresholds.start.n == 1  # bad_swing excluded

# Bad — hidden coupling to filesystem
def test_derive_thresholds_filters_bad_reps():
    rows = load_stats_csv("tests/fixtures/mixed_quality.csv")
    ...
```

### 4.3 Deterministic randomness

Any test exercising bootstrap or other RNG code must pass a fixed seed
and assert on specific numeric output. Non-deterministic tests rot
quickly.

### 4.4 `tmp_path` for file IO

Use pytest's `tmp_path` fixture for tests that write files:

```python
def test_write_thresholds_json_shape(tmp_path):
    out = tmp_path / "thresholds.json"
    write_thresholds_json(curl, dataset_summary, out)
    payload = json.loads(out.read_text())
    assert "curl" in payload
```

### 4.5 `monkeypatch` for module-level state

If the code reads env vars or module-level constants, patch them via
`monkeypatch` so tests don't leak state into each other.

---

## 5. Non-test verification gates

Tests catch bugs in code. These other gates catch bugs in *data*, which
tests can't see:

### 5.1 Invariant check in `derive_thresholds.py`

As described in [`05_phase_D_threshold_math.md §5`](05_phase_D_threshold_math.md#5-fsm-invariants),
the script exits non-zero if the derived thresholds would produce an
un-enterable FSM.

### 5.2 Replay F1 in `dart_replay`

As described in [`04_phase_E_replay.md`](04_phase_E_replay.md), the
replay harness scores the FSM on the whole dataset and produces a
Markdown report. Pass criteria: overall F1 ≥ 0.95, no clip < 0.85.

### 5.3 `flutter analyze`

Two places:
- Repo root: catches Dart type errors in `app/` (the app itself).
- `dart_replay/`: catches errors in the harness. Must run *after*
  `flutter pub get` has resolved the `path:` dep.

Both should report 0 issues. The harness excludes `bin/**` from the
top-level analyze to avoid false positives before `pub get` is run —
see [`04_phase_E_replay.md §6`](04_phase_E_replay.md#6-the-analysis_optionsyaml-rationale).

### 5.4 `git diff` on generated Dart

The generated `app/lib/core/default_rom_thresholds.dart` is committed.
Every time you re-run the pipeline, inspect the diff:

```bash
git diff app/lib/core/default_rom_thresholds.dart
```

Every change to a constant should be defensible by pointing at
`thresholds.json`. A surprise diff (threshold moved but data didn't) is
a bug somewhere.

### 5.5 Manual notebook review

`notebooks/01_explore_distributions.ipynb` is not a test, but running
it before shipping new thresholds catches issues tests can't:

- Per-subject row counts — is one subject dominating the percentiles?
- Per-view (front vs side) — do front-view reps systematically differ?
- Angle histogram shape — bimodal? Hints at a mixed-population dataset
  that the single-percentile model doesn't handle.

---

## 6. What's not tested (yet)

- **Real video end-to-end.** `extract_keypoints.py` is only smoke-tested
  via optional imports. No test drives MediaPipe on a real video — that
  would require a committed fixture video, which we've refused.
- **Dart-side tests for `replay.dart`.** The harness has no unit tests
  of its own. It's simple enough (~330 lines, mostly IO) that we've
  accepted the risk, but if it grows it should get tests.
- **CI pipeline.** No GitHub Actions workflow runs pytest today. The
  hooks are there (exit codes, deterministic output) but not wired —
  see [`02_pipeline_runbook.md §9`](02_pipeline_runbook.md#9-ci--automation-future).
- **Multiple exercise types.** The current tests assume biceps curls.
  Adding squats or deadlifts would require parallel threshold derivation
  and a parallel test suite.

These are known gaps, not mistakes. Document them when they become
blockers.
