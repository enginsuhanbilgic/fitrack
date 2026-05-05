"""Synthetic unit tests for scripts/phase_b_auto_annotate.py.

`detect_reps` is a pure function over a smoothed elbow-angle series — every
test here builds a float list in memory and asserts the emitted
`(start, peak, end)` triples. Integration tests also exercise
`detect_for_clip` with minimal landmark fixtures and the CSV writer through
`tmp_path`.
"""

from __future__ import annotations

import csv
from pathlib import Path

import pytest

from scripts.angle_utils import Landmark
from scripts.compute_rep_stats import VideoRow
from scripts.jsonl_io import FrameSample
from scripts.landmark_indices import (
    LANDMARK_COUNT,
    RIGHT_ELBOW,
    RIGHT_SHOULDER,
    RIGHT_WRIST,
)
from scripts.phase_b_auto_annotate import (
    MIN_DWELL_FRAMES,
    MIN_EXCURSION_DEG,
    DetectedRep,
    detect_for_clip,
    detect_reps,
    write_reps_csv,
)


# ---------------------------------------------------------------------------
# Angle-series builders
# ---------------------------------------------------------------------------


def _triangle_wave(
    reps: int,
    half_period_frames: int,
    max_angle: float,
    min_angle: float,
) -> list[float]:
    """N reps of a symmetric triangle: max → min → max → min → ... → max.

    Each rep contributes `2 * half_period_frames` samples (descent + ascent)
    plus a shared boundary, so the series length is
    `reps * 2 * half_period_frames + 1`.
    """
    out: list[float] = []
    value = max_angle
    step = (max_angle - min_angle) / half_period_frames
    out.append(value)
    for _ in range(reps):
        # descent
        for _ in range(half_period_frames):
            value -= step
            out.append(value)
        # ascent
        for _ in range(half_period_frames):
            value += step
            out.append(value)
    return out


# ---------------------------------------------------------------------------
# detect_reps — happy path
# ---------------------------------------------------------------------------


def test_detect_reps_finds_three_clean_reps() -> None:
    # 3 reps of 160° → 70° → 160°, 12-frame halves → plenty above min dwell.
    angles = _triangle_wave(reps=3, half_period_frames=12, max_angle=160.0, min_angle=70.0)

    reps = detect_reps(angles)

    assert len(reps) == 3
    # First rep: starts at frame 0 (first peak), dips at frame 12, ends at 24.
    assert reps[0] == (0, 12, 24)
    assert reps[1] == (24, 36, 48)
    assert reps[2] == (48, 60, 72)


def test_detect_reps_on_single_rep() -> None:
    angles = _triangle_wave(reps=1, half_period_frames=10, max_angle=155.0, min_angle=65.0)

    reps = detect_reps(angles)

    assert reps == [(0, 10, 20)]


# ---------------------------------------------------------------------------
# detect_reps — gating
# ---------------------------------------------------------------------------


def test_detect_reps_rejects_below_excursion_threshold() -> None:
    # Peak-to-trough only 30° — below the 40° excursion gate.
    angles = _triangle_wave(reps=2, half_period_frames=12, max_angle=160.0, min_angle=130.0)

    reps = detect_reps(angles)

    assert reps == []


def test_detect_reps_honours_custom_excursion_gate() -> None:
    # 30° excursion passes when we explicitly lower the gate.
    angles = _triangle_wave(reps=2, half_period_frames=12, max_angle=160.0, min_angle=130.0)

    reps = detect_reps(angles, min_excursion=25.0)

    assert len(reps) == 2


def test_detect_reps_rejects_chatter_below_dwell_gate() -> None:
    # Half-period 3 frames → every flip falls under the 8-frame dwell guard.
    # The dwell gate swallows intermediate oscillations; at most one terminal
    # rep can survive when the last streak crosses the gate.
    angles = _triangle_wave(reps=4, half_period_frames=3, max_angle=160.0, min_angle=70.0)

    reps = detect_reps(angles)

    # 4 oscillations flattened to ≤1 rep — we care that chatter is compressed,
    # not the exact count.
    assert len(reps) <= 1


def test_detect_reps_honours_custom_dwell_gate() -> None:
    # Same chatter series, but drop dwell to 2 → reps now surface.
    angles = _triangle_wave(reps=4, half_period_frames=3, max_angle=160.0, min_angle=70.0)

    reps = detect_reps(angles, min_dwell_frames=2)

    assert len(reps) == 4


# ---------------------------------------------------------------------------
# detect_reps — robustness edges
# ---------------------------------------------------------------------------


def test_detect_reps_empty_series_returns_empty() -> None:
    assert detect_reps([]) == []


def test_detect_reps_all_none_returns_empty() -> None:
    assert detect_reps([None, None, None, None]) == []


def test_detect_reps_ignores_flat_prefix() -> None:
    # Leading flat section, then one clean rep — flat frames must not seed
    # spurious extrema.
    flat = [160.0] * 5
    rep = _triangle_wave(reps=1, half_period_frames=12, max_angle=160.0, min_angle=70.0)
    angles = flat + rep[1:]  # avoid doubling the shared boundary

    reps = detect_reps(angles)

    assert len(reps) == 1
    s, p, e = reps[0]
    assert s < p < e
    # The rep must span a ≥40° excursion and land wholly in the moving section.
    assert e - s == 24  # full triangle rep spans descent + ascent


def test_detect_reps_tolerates_none_holes() -> None:
    # One clean rep with a missing frame mid-descent. None frames hold last
    # direction, so the (max,min,max) triple still resolves.
    angles: list[float | None] = list(
        _triangle_wave(reps=1, half_period_frames=12, max_angle=160.0, min_angle=70.0)
    )
    angles[6] = None  # drop a sample mid-descent

    reps = detect_reps(angles)

    assert len(reps) == 1


# ---------------------------------------------------------------------------
# detect_for_clip — quality propagation and landmarks plumbing
# ---------------------------------------------------------------------------


def _blank_landmarks() -> list[Landmark | None]:
    return [None] * LANDMARK_COUNT


def _frame_with_right_arm(frame: int, elbow_x: float) -> FrameSample:
    """Right arm with fixed shoulder/wrist and a moving elbow in x.

    Shoulder at (0.60, 0.40), wrist at (0.60, 0.80) sits straight; bending the
    elbow outward (higher `elbow_x`) tightens the elbow angle. elbow_x=0.60 →
    180°; 0.80 → 90°. Sliding between a tight and loose value traces an
    excursion > 40° — enough to drive `detect_reps` from a real
    `FrameSample` list.
    """
    lms = _blank_landmarks()
    lms[RIGHT_SHOULDER] = Landmark(x=0.60, y=0.40, confidence=1.0)
    lms[RIGHT_ELBOW] = Landmark(x=elbow_x, y=0.60, confidence=1.0)
    lms[RIGHT_WRIST] = Landmark(x=0.60, y=0.80, confidence=1.0)
    return FrameSample(frame=frame, t_ms=frame * 33, landmarks=lms)


def _video_row(quality: str) -> VideoRow:
    return VideoRow(
        clip_id="clip_001",
        subject_id="subj_a",
        view="side",
        side="right",
        arm="right",
        fps=30,
        notes="",
        intended_quality=quality,
    )


def test_detect_for_clip_propagates_valid_quality() -> None:
    # Synthesize frames whose elbow_x oscillates to produce a rep-like angle
    # trace. elbow_x=0.60 → straight (180°); 0.80 → bent (~90°). Triangle
    # pattern with 12-frame halves, 3 reps = 73 frames.
    pattern = _triangle_wave(
        reps=3, half_period_frames=12, max_angle=0.60, min_angle=0.80
    )
    frames = [_frame_with_right_arm(i, x) for i, x in enumerate(pattern)]

    video = _video_row(quality="good")
    reps = detect_for_clip(video, frames)

    assert len(reps) >= 1
    assert all(r.quality == "good" for r in reps)
    assert all(r.clip_id == "clip_001" for r in reps)
    assert [r.rep_idx for r in reps] == list(range(len(reps)))


def test_detect_for_clip_sanitises_invalid_quality() -> None:
    pattern = _triangle_wave(
        reps=2, half_period_frames=12, max_angle=0.60, min_angle=0.80
    )
    frames = [_frame_with_right_arm(i, x) for i, x in enumerate(pattern)]

    video = _video_row(quality="mystery_label")
    reps = detect_for_clip(video, frames)

    # Invalid label blanks out so downstream Phase C skips these rows.
    assert all(r.quality == "" for r in reps)


def test_detect_for_clip_accepts_empty_quality() -> None:
    pattern = _triangle_wave(
        reps=2, half_period_frames=12, max_angle=0.60, min_angle=0.80
    )
    frames = [_frame_with_right_arm(i, x) for i, x in enumerate(pattern)]

    video = _video_row(quality="")
    reps = detect_for_clip(video, frames)

    assert all(r.quality == "" for r in reps)


# ---------------------------------------------------------------------------
# CSV round-trip
# ---------------------------------------------------------------------------


def test_write_reps_csv_round_trip(tmp_path: Path) -> None:
    rows = [
        DetectedRep("clip_001", 0, 0, 12, 24, "good"),
        DetectedRep("clip_001", 1, 24, 36, 48, "good"),
        DetectedRep("clip_002", 0, 5, 18, 31, "bad_swing"),
    ]
    out = tmp_path / "reps.csv"

    write_reps_csv(out, rows)

    with out.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        disk = list(reader)

    assert [r["clip_id"] for r in disk] == ["clip_001", "clip_001", "clip_002"]
    assert [r["rep_idx"] for r in disk] == ["0", "1", "0"]
    assert [r["quality"] for r in disk] == ["good", "good", "bad_swing"]
    assert disk[0]["start_frame"] == "0"
    assert disk[0]["peak_frame"] == "12"
    assert disk[0]["end_frame"] == "24"


def test_write_reps_csv_creates_parent_dirs(tmp_path: Path) -> None:
    nested = tmp_path / "nested" / "dirs" / "reps.csv"

    write_reps_csv(nested, [])

    assert nested.exists()
    content = nested.read_text(encoding="utf-8")
    assert content.startswith("clip_id,rep_idx,start_frame,peak_frame,end_frame,quality")


# ---------------------------------------------------------------------------
# Gate defaults match the Dart shipping constants
# ---------------------------------------------------------------------------


def test_default_gates_match_shipping_constants() -> None:
    # Defensive: these constants mirror the Dart rep_boundary_detector.
    # If they drift, either fix the script or update the Dart side.
    assert MIN_EXCURSION_DEG == 40.0
    assert MIN_DWELL_FRAMES == 8
