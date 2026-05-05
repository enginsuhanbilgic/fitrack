"""Synthetic unit tests for scripts/compute_rep_stats.py.

No video, no MediaPipe, no CSVs on disk unless tmp_path is used — every test
builds FrameSample fixtures in memory and exercises one aggregator branch.
"""

from __future__ import annotations

import csv
import io
import math
from pathlib import Path

import pytest

from scripts.angle_utils import Landmark
from scripts.compute_rep_stats import (
    RepRow,
    RepStats,
    VideoRow,
    _median,
    _read_reps_csv,
    _read_videos_csv,
    build_parser,
    compute_rep_stats,
    elbow_angle_for_arm,
    iter_rep_stats,
    torso_length,
    write_stats_csv,
)
from scripts.jsonl_io import FrameSample
from scripts.landmark_indices import (
    LANDMARK_COUNT,
    LEFT_ELBOW,
    LEFT_HIP,
    LEFT_SHOULDER,
    LEFT_WRIST,
    RIGHT_ELBOW,
    RIGHT_HIP,
    RIGHT_SHOULDER,
    RIGHT_WRIST,
)


# ---------------------------------------------------------------------------
# Fixture builders — keep tests readable by constructing poses, not lists.
# ---------------------------------------------------------------------------


def _blank_landmarks() -> list[Landmark | None]:
    """33 None slots so we can set only the indices we care about per test."""
    return [None] * LANDMARK_COUNT


def _set(
    lms: list[Landmark | None],
    index: int,
    x: float,
    y: float,
    confidence: float = 1.0,
) -> None:
    lms[index] = Landmark(x=x, y=y, confidence=confidence)


def _straight_arm_right(lms: list[Landmark | None], y: float = 0.5) -> None:
    """Right-arm shoulder/elbow/wrist collinear → 180° elbow angle."""
    _set(lms, RIGHT_SHOULDER, 0.60, y)
    _set(lms, RIGHT_ELBOW, 0.60, y + 0.1)
    _set(lms, RIGHT_WRIST, 0.60, y + 0.2)


def _bent_arm_right(lms: list[Landmark | None]) -> None:
    """Right arm at ~90° — elbow below shoulder, wrist level with shoulder."""
    _set(lms, RIGHT_SHOULDER, 0.60, 0.40)
    _set(lms, RIGHT_ELBOW, 0.60, 0.50)
    _set(lms, RIGHT_WRIST, 0.70, 0.50)


def _torso(lms: list[Landmark | None], shoulder_y: float, hip_y: float) -> None:
    _set(lms, LEFT_SHOULDER, 0.40, shoulder_y)
    _set(lms, RIGHT_SHOULDER, 0.60, shoulder_y)
    _set(lms, LEFT_HIP, 0.42, hip_y)
    _set(lms, RIGHT_HIP, 0.58, hip_y)


def _sample(frame: int, lms: list[Landmark | None], t_ms: int = 0) -> FrameSample:
    return FrameSample(frame=frame, t_ms=t_ms, landmarks=lms)


def _video_row(arm: str = "right", fps: int = 30) -> VideoRow:
    return VideoRow(
        clip_id="clip_001",
        subject_id="subj_a",
        view="side",
        side="right",
        arm=arm,
        fps=fps,
        notes="",
    )


def _rep_row(
    rep_idx: int = 1,
    start: int = 0,
    peak: int = 15,
    end: int = 30,
    quality: str = "good",
) -> RepRow:
    return RepRow(
        clip_id="clip_001",
        rep_idx=rep_idx,
        start_frame=start,
        peak_frame=peak,
        end_frame=end,
        quality=quality,
    )


# ---------------------------------------------------------------------------
# elbow_angle_for_arm
# ---------------------------------------------------------------------------


def test_elbow_angle_for_arm_left_only_uses_left_triplet():
    lms = _blank_landmarks()
    _set(lms, LEFT_SHOULDER, 0.40, 0.40)
    _set(lms, LEFT_ELBOW, 0.40, 0.50)
    _set(lms, LEFT_WRIST, 0.40, 0.60)  # straight -> 180
    sample = _sample(0, lms)
    assert elbow_angle_for_arm(sample, "left") == pytest.approx(180.0, abs=1e-6)


def test_elbow_angle_for_arm_right_ignores_left_triplet():
    lms = _blank_landmarks()
    # Only right side filled — left side is None.
    _bent_arm_right(lms)
    sample = _sample(0, lms)
    angle = elbow_angle_for_arm(sample, "right")
    assert angle is not None
    assert 85.0 < angle < 95.0
    # Left is missing, so "left" request must return None.
    assert elbow_angle_for_arm(sample, "left") is None


def test_elbow_angle_for_arm_both_averages_when_both_valid():
    lms = _blank_landmarks()
    # Left straight (180°)
    _set(lms, LEFT_SHOULDER, 0.40, 0.40)
    _set(lms, LEFT_ELBOW, 0.40, 0.50)
    _set(lms, LEFT_WRIST, 0.40, 0.60)
    # Right bent (~90°)
    _bent_arm_right(lms)
    sample = _sample(0, lms)
    angle = elbow_angle_for_arm(sample, "both")
    assert angle is not None
    # (180 + ~90) / 2 ≈ 135
    assert 130.0 < angle < 140.0


def test_elbow_angle_for_arm_both_falls_back_to_single_side():
    """When only one side is valid, `both` returns that side's angle verbatim."""
    lms = _blank_landmarks()
    _straight_arm_right(lms)
    sample = _sample(0, lms)
    right_only = elbow_angle_for_arm(sample, "right")
    assert elbow_angle_for_arm(sample, "both") == right_only


def test_elbow_angle_for_arm_returns_none_when_both_sides_missing():
    sample = _sample(0, _blank_landmarks())
    assert elbow_angle_for_arm(sample, "both") is None
    assert elbow_angle_for_arm(sample, "left") is None
    assert elbow_angle_for_arm(sample, "right") is None


# ---------------------------------------------------------------------------
# torso_length
# ---------------------------------------------------------------------------


def test_torso_length_is_abs_vertical_midpoint_gap():
    lms = _blank_landmarks()
    _torso(lms, shoulder_y=0.30, hip_y=0.70)
    sample = _sample(0, lms)
    # shoulder_mid_y = 0.30, hip_mid_y = 0.70 -> 0.40
    assert torso_length(sample) == pytest.approx(0.40)


def test_torso_length_symmetric_under_flipped_positions():
    """Shoulders below hips (upside-down) should still yield a positive length."""
    lms = _blank_landmarks()
    _torso(lms, shoulder_y=0.70, hip_y=0.30)
    assert torso_length(_sample(0, lms)) == pytest.approx(0.40)


def test_torso_length_none_when_any_torso_landmark_missing():
    lms = _blank_landmarks()
    _set(lms, LEFT_SHOULDER, 0.40, 0.30)
    _set(lms, RIGHT_SHOULDER, 0.60, 0.30)
    _set(lms, LEFT_HIP, 0.42, 0.70)
    # RIGHT_HIP intentionally omitted.
    assert torso_length(_sample(0, lms)) is None


# ---------------------------------------------------------------------------
# _median — tiny pure helper, worth locking down.
# ---------------------------------------------------------------------------


def test_median_odd_count():
    assert _median([3.0, 1.0, 2.0]) == 2.0


def test_median_even_count_averages_middle_two():
    assert _median([1.0, 2.0, 3.0, 4.0]) == pytest.approx(2.5)


def test_median_raises_on_empty():
    with pytest.raises(ValueError):
        _median([])


# ---------------------------------------------------------------------------
# compute_rep_stats — the full per-rep pipeline on synthetic streams.
# ---------------------------------------------------------------------------


def _build_ramp_frames(n_frames: int, fps: int = 30) -> list[FrameSample]:
    """A clip where the right elbow ramps from 180° (straight) down to ~60° (curled).

    Shoulders and hips stay still; only the wrist moves toward the shoulder,
    decreasing the elbow angle linearly frame by frame.
    """
    frames: list[FrameSample] = []
    for i in range(n_frames):
        lms = _blank_landmarks()
        _torso(lms, shoulder_y=0.30, hip_y=0.70)
        # Elbow stays put; wrist arcs from straight-down to near-shoulder.
        # Start: wrist at (0.60, 0.60) -> straight. End: wrist close to shoulder.
        t = i / max(n_frames - 1, 1)  # 0 at frame 0, 1 at last
        # Move wrist Y from 0.60 up to 0.32 (near shoulder) and X outward slightly.
        wrist_y = 0.60 - 0.28 * t
        wrist_x = 0.60 + 0.05 * t
        _set(lms, RIGHT_ELBOW, 0.60, 0.45)
        _set(lms, RIGHT_WRIST, wrist_x, wrist_y)
        frames.append(_sample(frame=i, lms=lms, t_ms=int(i * 1000 / fps)))
    return frames


def test_compute_rep_stats_reports_min_max_rom_over_window():
    frames = _build_ramp_frames(31)
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=30, end=30)  # full ramp
    stats = compute_rep_stats(video, rep, frames)
    # Straight arm (~180°) at start, deeply bent at end -> min < start_angle.
    assert stats.max_angle is not None and stats.max_angle > 170.0
    assert stats.min_angle is not None and stats.min_angle < 90.0
    assert stats.rom is not None
    assert stats.rom == pytest.approx(stats.max_angle - stats.min_angle, abs=1e-6)


def test_compute_rep_stats_concentric_and_eccentric_ms_use_fps():
    frames = _build_ramp_frames(31, fps=30)
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=15, end=30)
    stats = compute_rep_stats(video, rep, frames)
    # 15 frames @ 30fps = 500 ms each half.
    assert stats.concentric_ms == 500
    assert stats.eccentric_ms == 500


def test_compute_rep_stats_start_peak_end_angles_match_window_positions():
    frames = _build_ramp_frames(31, fps=30)
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=15, end=30)
    stats = compute_rep_stats(video, rep, frames)
    # Start must be near 180 (straight), end must be deeply bent.
    assert stats.start_angle is not None and stats.start_angle > 170.0
    assert stats.end_angle is not None and stats.end_angle < 90.0
    # Peak is the mid-frame (15) — monotonic ramp so peak lies between them.
    assert stats.peak_angle is not None
    assert stats.end_angle < stats.peak_angle < stats.start_angle


def test_compute_rep_stats_shoulder_drift_is_zero_when_shoulder_static():
    frames = _build_ramp_frames(31)
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=15, end=30)
    stats = compute_rep_stats(video, rep, frames)
    # Ramp fixture holds shoulder at y=0.30 constant -> zero drift.
    assert stats.shoulder_drift_norm == pytest.approx(0.0, abs=1e-9)


def test_compute_rep_stats_wrist_swing_normalised_by_torso():
    frames = _build_ramp_frames(31)
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=15, end=30)
    stats = compute_rep_stats(video, rep, frames)
    # Wrist X moves 0.05 across ramp; torso = 0.40 -> swing ≈ 0.125
    assert stats.wrist_swing_norm is not None
    assert stats.wrist_swing_norm == pytest.approx(0.05 / 0.40, rel=1e-3)


def test_compute_rep_stats_valid_frame_ratio_counts_only_smoothed_angles():
    # Half the frames have no right-arm landmarks -> half are invalid.
    frames: list[FrameSample] = []
    for i in range(10):
        lms = _blank_landmarks()
        _torso(lms, shoulder_y=0.30, hip_y=0.70)
        if i % 2 == 0:
            _straight_arm_right(lms)
        frames.append(_sample(i, lms, t_ms=i * 33))
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=5, end=9)
    stats = compute_rep_stats(video, rep, frames)
    assert 0.0 < stats.valid_frame_ratio <= 1.0


def test_compute_rep_stats_raises_on_inverted_window():
    video = _video_row()
    rep = _rep_row(start=30, peak=15, end=10)  # end < start
    with pytest.raises(ValueError):
        compute_rep_stats(video, rep, [])


def test_compute_rep_stats_all_none_when_landmarks_missing():
    """No landmarks at all -> stats degrade gracefully to None fields."""
    frames = [_sample(i, _blank_landmarks(), t_ms=i * 33) for i in range(10)]
    video = _video_row(arm="right", fps=30)
    rep = _rep_row(start=0, peak=5, end=9)
    stats = compute_rep_stats(video, rep, frames)
    assert stats.min_angle is None
    assert stats.max_angle is None
    assert stats.rom is None
    assert stats.start_angle is None
    assert stats.peak_angle is None
    assert stats.end_angle is None
    assert stats.shoulder_drift_norm is None
    assert stats.wrist_swing_norm is None
    assert stats.valid_frame_ratio == 0.0


# ---------------------------------------------------------------------------
# RepStats CSV row / header
# ---------------------------------------------------------------------------


def test_rep_stats_csv_header_matches_dataclass_field_order():
    expected = [
        "clip_id", "subject_id", "view", "side", "arm", "rep_idx", "quality",
        "fps", "start_frame", "peak_frame", "end_frame",
        "min_angle", "max_angle", "rom", "start_angle", "peak_angle",
        "end_angle", "concentric_ms", "eccentric_ms",
        "shoulder_drift_norm", "wrist_swing_norm", "valid_frame_ratio",
    ]
    assert RepStats.csv_header() == expected


def test_rep_stats_as_csv_row_formats_floats_and_emits_blank_for_none():
    stats = RepStats(
        clip_id="c1", subject_id="s1", view="side", side="right", arm="right",
        rep_idx=1, quality="good", fps=30,
        start_frame=0, peak_frame=15, end_frame=30,
        min_angle=None, max_angle=170.0, rom=None,
        start_angle=160.1235, peak_angle=None, end_angle=155.0,
        concentric_ms=500, eccentric_ms=500,
        shoulder_drift_norm=0.0, wrist_swing_norm=0.12345,
        valid_frame_ratio=1.0,
    )
    row = stats.as_csv_row()
    header = RepStats.csv_header()
    assert len(row) == len(header)
    fields = dict(zip(header, row))
    # None -> empty string
    assert fields["min_angle"] == ""
    assert fields["rom"] == ""
    assert fields["peak_angle"] == ""
    # Float formatting
    assert fields["max_angle"] == "170.0000"
    assert fields["start_angle"] == "160.1235"
    assert fields["wrist_swing_norm"] == "0.1235"
    # Ints as-is
    assert fields["rep_idx"] == "1"
    assert fields["concentric_ms"] == "500"


# ---------------------------------------------------------------------------
# write_stats_csv — header always written even when rows are empty.
# ---------------------------------------------------------------------------


def test_write_stats_csv_writes_header_only_for_empty_iterable(tmp_path: Path):
    out = tmp_path / "per_rep_stats.csv"
    written = write_stats_csv([], out)
    assert written == 0
    content = out.read_text(encoding="utf-8").splitlines()
    assert len(content) == 1
    assert content[0].split(",") == RepStats.csv_header()


def test_write_stats_csv_round_trip_single_row(tmp_path: Path):
    out = tmp_path / "per_rep_stats.csv"
    stats = RepStats(
        clip_id="c1", subject_id="s1", view="side", side="right", arm="right",
        rep_idx=1, quality="good", fps=30,
        start_frame=0, peak_frame=15, end_frame=30,
        min_angle=60.0, max_angle=170.0, rom=110.0,
        start_angle=165.0, peak_angle=62.0, end_angle=160.0,
        concentric_ms=500, eccentric_ms=500,
        shoulder_drift_norm=0.05, wrist_swing_norm=0.08,
        valid_frame_ratio=0.95,
    )
    written = write_stats_csv([stats], out)
    assert written == 1
    with out.open("r", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 1
    assert rows[0]["clip_id"] == "c1"
    assert rows[0]["rep_idx"] == "1"
    assert float(rows[0]["rom"]) == pytest.approx(110.0)


# ---------------------------------------------------------------------------
# _read_videos_csv / _read_reps_csv — ensure CSV parsing is forgiving.
# ---------------------------------------------------------------------------


def test_read_videos_csv_normalises_whitespace_and_case(tmp_path: Path):
    path = tmp_path / "videos.csv"
    path.write_text(
        "clip_id,subject_id,view,side,arm,fps,notes\n"
        " clip_001 , subj_a , SIDE , Right , Right , 30 ,  some note \n",
        encoding="utf-8",
    )
    videos = _read_videos_csv(path)
    assert "clip_001" in videos
    v = videos["clip_001"]
    assert v.view == "side"
    assert v.side == "right"
    assert v.arm == "right"
    assert v.fps == 30
    assert v.notes == "some note"


def test_read_reps_csv_parses_ints_and_lowercases_quality(tmp_path: Path):
    path = tmp_path / "reps.csv"
    path.write_text(
        "clip_id,rep_idx,start_frame,peak_frame,end_frame,quality\n"
        "clip_001,1,0,15,30,GOOD\n"
        "clip_001,2,31,44,60,Bad_Swing\n",
        encoding="utf-8",
    )
    reps = _read_reps_csv(path)
    assert len(reps) == 2
    assert reps[0].rep_idx == 1
    assert reps[0].quality == "good"
    assert reps[1].quality == "bad_swing"
    assert reps[1].end_frame == 60


# ---------------------------------------------------------------------------
# iter_rep_stats — skipping behaviour when clip metadata or keypoints absent.
# ---------------------------------------------------------------------------


def test_iter_rep_stats_skips_reps_whose_clip_is_missing_from_videos(capsys):
    reps = [_rep_row()]  # clip_001
    out = list(iter_rep_stats({}, reps, Path("/nonexistent")))
    assert out == []
    err = capsys.readouterr().err
    assert "clip_id 'clip_001'" in err


def test_iter_rep_stats_skips_reps_whose_keypoints_file_is_missing(
    tmp_path: Path, capsys
):
    videos = {"clip_001": _video_row()}
    reps = [_rep_row()]
    out = list(iter_rep_stats(videos, reps, tmp_path))  # no jsonl present
    assert out == []
    err = capsys.readouterr().err
    assert "keypoints file missing" in err


def test_iter_rep_stats_yields_when_all_inputs_present(tmp_path: Path):
    # Build a minimal JSONL file so load_frames succeeds.
    jsonl = tmp_path / "clip_001.jsonl"
    lines = []
    for i in range(5):
        # 33 landmarks per row — all the same, but schema-valid.
        landmarks = [
            {"x": 0.5, "y": 0.5, "z": 0.0, "v": 0.9} for _ in range(LANDMARK_COUNT)
        ]
        import json as _json
        lines.append(_json.dumps({"frame": i, "t_ms": i * 33, "landmarks": landmarks}))
    jsonl.write_text("\n".join(lines) + "\n", encoding="utf-8")

    videos = {"clip_001": _video_row(arm="right")}
    reps = [_rep_row(start=0, peak=2, end=4)]
    out = list(iter_rep_stats(videos, reps, tmp_path))
    assert len(out) == 1
    # With all landmarks collapsed onto the same point, elbow "angle" is
    # ill-defined but should not crash — result is just fine as long as we
    # got a RepStats back.
    assert out[0].clip_id == "clip_001"
    assert out[0].rep_idx == 1


# ---------------------------------------------------------------------------
# build_parser — defaults and accepted overrides.
# ---------------------------------------------------------------------------


def test_parser_accepts_overrides_and_uses_defaults_when_absent():
    parser = build_parser()
    ns = parser.parse_args([])
    # Defaults resolve to Path objects under data/...
    assert isinstance(ns.videos_csv, Path)
    assert ns.videos_csv.name == "videos.csv"
    assert ns.reps_csv.name == "reps.csv"
    assert ns.out.name == "per_rep_stats.csv"


def test_parser_accepts_custom_paths():
    parser = build_parser()
    ns = parser.parse_args(
        [
            "--videos-csv", "a/v.csv",
            "--reps-csv", "a/r.csv",
            "--keypoints-dir", "a/kp",
            "--out", "a/out.csv",
        ]
    )
    assert ns.videos_csv == Path("a/v.csv")
    assert ns.reps_csv == Path("a/r.csv")
    assert ns.keypoints_dir == Path("a/kp")
    assert ns.out == Path("a/out.csv")
