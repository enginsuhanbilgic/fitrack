"""Unit tests for helpers in scripts/extract_keypoints.py.

Every test here avoids MediaPipe and OpenCV entirely — only the pure helpers
(JSON serialisation, path math, staleness check, CLI wiring) are exercised.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

import pytest

from scripts.extract_keypoints import (
    FrameRecord,
    VIDEO_EXTENSIONS,
    _landmarks_to_dicts,
    build_parser,
    default_output_path,
    discover_videos,
    is_stale,
)


# ---------------------------------------------------------------------------
# FrameRecord
# ---------------------------------------------------------------------------


def test_frame_record_emits_single_line_json():
    record = FrameRecord(
        frame=42,
        t_ms=1400,
        landmarks=[{"x": 0.5, "y": 0.3, "z": -0.1, "v": 0.98}],
    )
    line = record.to_json_line()
    assert "\n" not in line
    parsed = json.loads(line)
    assert parsed == {
        "frame": 42,
        "t_ms": 1400,
        "landmarks": [{"x": 0.5, "y": 0.3, "z": -0.1, "v": 0.98}],
    }


def test_frame_record_empty_landmarks_for_missing_person():
    """Frames where MediaPipe fails to locate a person should emit `[]`."""
    record = FrameRecord(frame=0, t_ms=0, landmarks=[])
    parsed = json.loads(record.to_json_line())
    assert parsed["landmarks"] == []


def test_frame_record_schema_is_tight():
    """Only the four documented keys are allowed in a line — no drift."""
    record = FrameRecord(frame=1, t_ms=33, landmarks=[])
    parsed = json.loads(record.to_json_line())
    assert set(parsed.keys()) == {"frame", "t_ms", "landmarks"}


# ---------------------------------------------------------------------------
# _landmarks_to_dicts
# ---------------------------------------------------------------------------


class _FakeLandmark:
    """Stand-in for MediaPipe's NormalizedLandmark without importing it."""

    def __init__(self, x: float, y: float, z: float, visibility: float) -> None:
        self.x = x
        self.y = y
        self.z = z
        self.visibility = visibility


class _FakeLandmarkList:
    def __init__(self, landmark):
        self.landmark = landmark


def test_landmarks_to_dicts_none_returns_empty():
    assert _landmarks_to_dicts(None) == []


def test_landmarks_to_dicts_renames_visibility_to_v():
    mp_landmarks = _FakeLandmarkList(
        [
            _FakeLandmark(0.1, 0.2, -0.3, 0.95),
            _FakeLandmark(0.4, 0.5, -0.6, 0.42),
        ]
    )
    out = _landmarks_to_dicts(mp_landmarks)
    assert len(out) == 2
    assert set(out[0].keys()) == {"x", "y", "z", "v"}
    # Visibility must have been renamed to `v` — the app-side key.
    assert "visibility" not in out[0]
    assert out[0]["v"] == pytest.approx(0.95)


def test_landmarks_to_dicts_rounds_to_six_decimals():
    """JSONL stays small — 6 decimals is ~mm precision at normalised scale."""
    mp_landmarks = _FakeLandmarkList(
        [_FakeLandmark(0.1234567890, 0.0, 0.0, 1.0)]
    )
    out = _landmarks_to_dicts(mp_landmarks)
    assert out[0]["x"] == pytest.approx(0.123457)


# ---------------------------------------------------------------------------
# default_output_path
# ---------------------------------------------------------------------------


def test_default_output_path_swaps_extension_and_directory():
    video = Path("data/videos/clip_042_subj_side_right.mp4")
    out = default_output_path(video)
    assert out.name == "clip_042_subj_side_right.jsonl"
    assert out.parent.name == "keypoints"


def test_default_output_path_preserves_clip_id_even_for_weird_extensions():
    assert default_output_path(Path("foo.MOV")).name == "foo.jsonl"


# ---------------------------------------------------------------------------
# discover_videos / is_stale
# ---------------------------------------------------------------------------


def test_discover_videos_returns_sorted_known_extensions_only(tmp_path, monkeypatch):
    monkeypatch.setattr("scripts.extract_keypoints.VIDEOS_DIR", tmp_path)
    # Known extensions
    (tmp_path / "z.mp4").touch()
    (tmp_path / "a.mov").touch()
    # Unknown — must be skipped
    (tmp_path / "notes.txt").touch()
    (tmp_path / "thumbnail.jpg").touch()
    # Subdirectories — ignored (we don't recurse)
    (tmp_path / "subdir").mkdir()
    (tmp_path / "subdir" / "nested.mp4").touch()
    found = discover_videos()
    assert [p.name for p in found] == ["a.mov", "z.mp4"]


def test_video_extensions_contract():
    """If we add a new video extension, tests above need updating too."""
    assert VIDEO_EXTENSIONS == {".mp4", ".mov", ".m4v", ".avi"}


def test_is_stale_true_when_output_missing(tmp_path):
    video = tmp_path / "clip.mp4"
    out = tmp_path / "clip.jsonl"
    video.touch()
    assert is_stale(video, out) is True


def test_is_stale_false_when_output_newer(tmp_path):
    video = tmp_path / "clip.mp4"
    out = tmp_path / "clip.jsonl"
    video.touch()
    # Backdate the video, forward-date the output.
    old = time.time() - 1000
    new = time.time() - 10
    os.utime(video, (old, old))
    out.touch()
    os.utime(out, (new, new))
    assert is_stale(video, out) is False


def test_is_stale_true_when_output_older(tmp_path):
    video = tmp_path / "clip.mp4"
    out = tmp_path / "clip.jsonl"
    video.touch()
    out.touch()
    old = time.time() - 1000
    new = time.time() - 10
    # Output is older than video -> stale.
    os.utime(out, (old, old))
    os.utime(video, (new, new))
    assert is_stale(video, out) is True


# ---------------------------------------------------------------------------
# build_parser — CLI wiring sanity
# ---------------------------------------------------------------------------


def test_parser_requires_either_video_or_all():
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args([])


def test_parser_rejects_both_video_and_all():
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["--video", "foo.mp4", "--all"])


def test_parser_accepts_video_and_optional_out():
    parser = build_parser()
    ns = parser.parse_args(["--video", "foo.mp4", "--out", "bar.jsonl"])
    assert ns.video == Path("foo.mp4")
    assert ns.out == Path("bar.jsonl")
    assert ns.all is False


def test_parser_defaults_model_complexity_to_heavy():
    parser = build_parser()
    ns = parser.parse_args(["--all"])
    assert ns.model_complexity == 2


def test_parser_rejects_invalid_model_complexity():
    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["--all", "--model-complexity", "5"])
