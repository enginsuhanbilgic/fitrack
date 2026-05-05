"""Phase C — Aggregate per-rep statistics.

Inputs:
    data/keypoints/*.jsonl            (from extract_keypoints.py)
    data/annotations/videos.csv       (manual — per clip)
    data/annotations/reps.csv         (manual — per rep)

Output:
    data/derived/per_rep_stats.csv    (one row per annotated rep)

For each (clip_id, rep_idx) pair in reps.csv we window the clip's keypoint
stream to [start_frame .. end_frame], smooth the elbow angle using the same
3-frame moving average as the shipping FSM, then extract:

  * min/max/ROM elbow angles
  * start/peak/end angles at the annotated frames
  * concentric/eccentric duration in ms
  * shoulder drift and wrist swing, both normalised by torso length

Every per-rep computation is pure — no pandas required for the math — so the
aggregator remains unit-testable against synthetic fixtures.

Usage:
    python scripts/compute_rep_stats.py
    python scripts/compute_rep_stats.py --out custom.csv
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Iterator, Optional

from scripts.angle_utils import (
    Landmark,
    angle_deg,
    smooth_angle_series,
    vertical_dist,
)
from scripts.jsonl_io import FrameSample, load_frames
from scripts.landmark_indices import (
    CURL_LEFT_TRIPLET,
    CURL_RIGHT_TRIPLET,
    LEFT_HIP,
    LEFT_SHOULDER,
    LEFT_WRIST,
    RIGHT_HIP,
    RIGHT_SHOULDER,
    RIGHT_WRIST,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
KEYPOINTS_DIR = REPO_ROOT / "data" / "keypoints"
ANNOTATIONS_DIR = REPO_ROOT / "data" / "annotations"
DERIVED_DIR = REPO_ROOT / "data" / "derived"

DEFAULT_OUTPUT = DERIVED_DIR / "per_rep_stats.csv"


# ---------------------------------------------------------------------------
# Annotation rows
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class VideoRow:
    clip_id: str
    subject_id: str
    view: str  # front | side
    side: str  # left | right | both
    arm: str  # left | right | both
    fps: int
    notes: str
    # The quality the clip was recorded to exemplify. Propagated to every
    # auto-detected rep by `phase_b_auto_annotate.py` unless the annotator
    # hand-overrides a row. Optional for backward compatibility — clips
    # annotated before Phase B auto-annotation landed have no value here.
    intended_quality: str = ""  # good | bad_swing | bad_partial_rom | bad_speed | ""


@dataclass(frozen=True)
class RepRow:
    clip_id: str
    rep_idx: int
    start_frame: int
    peak_frame: int
    end_frame: int
    quality: str  # good | bad_swing | bad_partial_rom | bad_speed


def _read_videos_csv(path: Path) -> dict[str, VideoRow]:
    rows: dict[str, VideoRow] = {}
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            row = VideoRow(
                clip_id=r["clip_id"].strip(),
                subject_id=r["subject_id"].strip(),
                view=r["view"].strip().lower(),
                side=r["side"].strip().lower(),
                arm=r["arm"].strip().lower(),
                fps=int(r["fps"]),
                notes=(r.get("notes") or "").strip(),
                intended_quality=(r.get("intended_quality") or "").strip().lower(),
            )
            rows[row.clip_id] = row
    return rows


def _read_reps_csv(path: Path) -> list[RepRow]:
    rows: list[RepRow] = []
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(
                RepRow(
                    clip_id=r["clip_id"].strip(),
                    rep_idx=int(r["rep_idx"]),
                    start_frame=int(r["start_frame"]),
                    peak_frame=int(r["peak_frame"]),
                    end_frame=int(r["end_frame"]),
                    quality=r["quality"].strip().lower(),
                )
            )
    return rows


# ---------------------------------------------------------------------------
# Angle / geometry helpers (pure; no pandas)
# ---------------------------------------------------------------------------


def elbow_angle_for_arm(sample: FrameSample, arm: str) -> Optional[float]:
    """Elbow angle in degrees for the requested arm.

    `arm` is one of "left", "right", "both". "both" averages whichever side
    produces a valid angle — matching rep_counter.dart._computeAngle so
    per-rep stats use the same signal the shipping FSM consumes.
    """
    left = _angle_from_triplet(sample, CURL_LEFT_TRIPLET)
    right = _angle_from_triplet(sample, CURL_RIGHT_TRIPLET)
    if arm == "left":
        return left
    if arm == "right":
        return right
    # "both" — average when available, fall back to whichever one is valid.
    if left is not None and right is not None:
        return (left + right) / 2.0
    return left if left is not None else right


def _angle_from_triplet(
    sample: FrameSample, triplet: tuple[int, int, int]
) -> Optional[float]:
    a, b, c = triplet
    return angle_deg(sample.landmark(a), sample.landmark(b), sample.landmark(c))


def torso_length(sample: FrameSample) -> Optional[float]:
    """Euclidean-equivalent vertical distance between shoulder- and hip-midpoints.

    We use vertical distance — the sum of |y| diffs — not full 2D distance
    because (a) `vertical_dist` is the existing app helper and (b) shoulder/
    hip X movement is exactly the drift/swing signal we *don't* want to
    normalise by. If shoulder or hip landmarks are low-confidence the method
    returns None so downstream stats skip the frame.
    """
    ls = sample.landmark(LEFT_SHOULDER)
    rs = sample.landmark(RIGHT_SHOULDER)
    lh = sample.landmark(LEFT_HIP)
    rh = sample.landmark(RIGHT_HIP)
    if ls is None or rs is None or lh is None or rh is None:
        return None
    # Average shoulder / hip Y
    shoulder_y = (ls.y + rs.y) / 2.0
    hip_y = (lh.y + rh.y) / 2.0
    return abs(shoulder_y - hip_y)


def _shoulder_y_for_arm(sample: FrameSample, arm: str) -> Optional[float]:
    if arm == "left":
        lm = sample.landmark(LEFT_SHOULDER)
        return lm.y if lm is not None else None
    if arm == "right":
        lm = sample.landmark(RIGHT_SHOULDER)
        return lm.y if lm is not None else None
    # both -> average
    ls = sample.landmark(LEFT_SHOULDER)
    rs = sample.landmark(RIGHT_SHOULDER)
    if ls is not None and rs is not None:
        return (ls.y + rs.y) / 2.0
    return ls.y if ls is not None else (rs.y if rs is not None else None)


def _wrist_x_for_arm(sample: FrameSample, arm: str) -> Optional[float]:
    if arm == "left":
        lm = sample.landmark(LEFT_WRIST)
        return lm.x if lm is not None else None
    if arm == "right":
        lm = sample.landmark(RIGHT_WRIST)
        return lm.x if lm is not None else None
    lw = sample.landmark(LEFT_WRIST)
    rw = sample.landmark(RIGHT_WRIST)
    if lw is not None and rw is not None:
        return (lw.x + rw.x) / 2.0
    return lw.x if lw is not None else (rw.x if rw is not None else None)


# ---------------------------------------------------------------------------
# Per-rep stat record
# ---------------------------------------------------------------------------


@dataclass
class RepStats:
    clip_id: str
    subject_id: str
    view: str
    side: str
    arm: str
    rep_idx: int
    quality: str
    fps: int
    start_frame: int
    peak_frame: int
    end_frame: int
    min_angle: Optional[float]
    max_angle: Optional[float]
    rom: Optional[float]
    start_angle: Optional[float]
    peak_angle: Optional[float]
    end_angle: Optional[float]
    concentric_ms: int
    eccentric_ms: int
    shoulder_drift_norm: Optional[float]
    wrist_swing_norm: Optional[float]
    valid_frame_ratio: float

    @staticmethod
    def csv_header() -> list[str]:
        return list(RepStats.__dataclass_fields__.keys())

    def as_csv_row(self) -> list[str]:
        row = []
        for field in RepStats.csv_header():
            value = getattr(self, field)
            if value is None:
                row.append("")
            elif isinstance(value, float):
                row.append(f"{value:.4f}")
            else:
                row.append(str(value))
        return row


# ---------------------------------------------------------------------------
# Core per-rep computation
# ---------------------------------------------------------------------------


def compute_rep_stats(
    video: VideoRow,
    rep: RepRow,
    frames: list[FrameSample],
) -> RepStats:
    """Compute one RepStats row. `frames` must be the full clip's stream."""
    if rep.end_frame < rep.start_frame:
        raise ValueError(
            f"Invalid annotation: end_frame {rep.end_frame} < "
            f"start_frame {rep.start_frame} in {rep.clip_id}/{rep.rep_idx}"
        )

    # Window the stream by frame index. Each frame sample carries its own
    # frame number, so we can tolerate gaps (though extract_keypoints emits
    # contiguous output in practice).
    window = [
        f for f in frames if rep.start_frame <= f.frame <= rep.end_frame
    ]
    total = max(len(window), 1)

    # Raw elbow angles for the working arm across the window.
    raw_angles: list[Optional[float]] = [
        elbow_angle_for_arm(f, video.arm) for f in window
    ]
    smoothed = smooth_angle_series(raw_angles)
    valid = [a for a in smoothed if a is not None]
    valid_ratio = len(valid) / total

    min_a = min(valid) if valid else None
    max_a = max(valid) if valid else None
    rom = (max_a - min_a) if (min_a is not None and max_a is not None) else None

    start_a = _angle_at_frame(window, smoothed, rep.start_frame)
    peak_a = _angle_at_frame(window, smoothed, rep.peak_frame)
    end_a = _angle_at_frame(window, smoothed, rep.end_frame)

    ms_per_frame = 1000.0 / max(video.fps, 1)
    concentric_ms = int(round((rep.peak_frame - rep.start_frame) * ms_per_frame))
    eccentric_ms = int(round((rep.end_frame - rep.peak_frame) * ms_per_frame))

    torso_lengths = [t for t in (torso_length(f) for f in window) if t is not None]
    torso_median = _median(torso_lengths) if torso_lengths else None

    shoulder_drift_norm = _shoulder_drift_norm(window, video.arm, torso_median)
    wrist_swing_norm = _wrist_swing_norm(window, video.arm, torso_median)

    return RepStats(
        clip_id=video.clip_id,
        subject_id=video.subject_id,
        view=video.view,
        side=video.side,
        arm=video.arm,
        rep_idx=rep.rep_idx,
        quality=rep.quality,
        fps=video.fps,
        start_frame=rep.start_frame,
        peak_frame=rep.peak_frame,
        end_frame=rep.end_frame,
        min_angle=min_a,
        max_angle=max_a,
        rom=rom,
        start_angle=start_a,
        peak_angle=peak_a,
        end_angle=end_a,
        concentric_ms=concentric_ms,
        eccentric_ms=eccentric_ms,
        shoulder_drift_norm=shoulder_drift_norm,
        wrist_swing_norm=wrist_swing_norm,
        valid_frame_ratio=valid_ratio,
    )


def _angle_at_frame(
    window: list[FrameSample],
    smoothed: list[Optional[float]],
    target_frame: int,
) -> Optional[float]:
    """Look up the smoothed angle for a specific frame index.

    Walks the parallel lists once. Returns None if the frame isn't in the
    window (shouldn't happen given annotation bounds, but we stay defensive).
    """
    for sample, value in zip(window, smoothed):
        if sample.frame == target_frame:
            return value
    return None


def _shoulder_drift_norm(
    window: list[FrameSample], arm: str, torso: Optional[float]
) -> Optional[float]:
    """Peak vertical shoulder excursion across the rep, normalised by torso.

    Uses Y because "shoulder drift" in the app means the shoulder rising
    during the curl (hike / shrug). Returns None when torso length is
    undefined or no valid shoulder samples exist.
    """
    if torso is None or torso <= 0:
        return None
    ys = [y for y in (_shoulder_y_for_arm(f, arm) for f in window) if y is not None]
    if not ys:
        return None
    return (max(ys) - min(ys)) / torso


def _wrist_swing_norm(
    window: list[FrameSample], arm: str, torso: Optional[float]
) -> Optional[float]:
    """Peak horizontal wrist excursion across the rep, normalised by torso.

    Wrist X swing catches pendulum-style body English on side-view curls.
    """
    if torso is None or torso <= 0:
        return None
    xs = [x for x in (_wrist_x_for_arm(f, arm) for f in window) if x is not None]
    if not xs:
        return None
    return (max(xs) - min(xs)) / torso


def _median(values: Iterable[float]) -> float:
    """Pure-Python median — avoids importing numpy for one call."""
    s = sorted(values)
    n = len(s)
    if n == 0:
        raise ValueError("median of empty sequence")
    mid = n // 2
    if n % 2 == 1:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2.0


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------


def iter_rep_stats(
    videos: dict[str, VideoRow],
    reps: Iterable[RepRow],
    keypoints_dir: Path,
) -> Iterator[RepStats]:
    """Yield one RepStats per rep annotation, skipping with clear errors."""
    frames_cache: dict[str, list[FrameSample]] = {}
    for rep in reps:
        video = videos.get(rep.clip_id)
        if video is None:
            print(
                f"warning: reps.csv references clip_id '{rep.clip_id}' "
                "not found in videos.csv — skipping",
                file=sys.stderr,
            )
            continue
        if rep.clip_id not in frames_cache:
            jsonl = keypoints_dir / f"{rep.clip_id}.jsonl"
            if not jsonl.exists():
                print(
                    f"warning: keypoints file missing for clip "
                    f"'{rep.clip_id}' ({jsonl}) — skipping rep",
                    file=sys.stderr,
                )
                continue
            frames_cache[rep.clip_id] = load_frames(jsonl)
        yield compute_rep_stats(video, rep, frames_cache[rep.clip_id])


def write_stats_csv(stats: Iterable[RepStats], out_path: Path) -> int:
    """Write a RepStats iterable to CSV. Returns the number of rows written."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(RepStats.csv_header())
        for row in stats:
            writer.writerow(row.as_csv_row())
            written += 1
    return written


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Aggregate per-rep angle/tempo/displacement statistics from "
            "extracted keypoints and manual annotations."
        )
    )
    parser.add_argument(
        "--videos-csv",
        type=Path,
        default=ANNOTATIONS_DIR / "videos.csv",
    )
    parser.add_argument(
        "--reps-csv",
        type=Path,
        default=ANNOTATIONS_DIR / "reps.csv",
    )
    parser.add_argument(
        "--keypoints-dir",
        type=Path,
        default=KEYPOINTS_DIR,
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUTPUT,
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if not args.videos_csv.exists() or not args.reps_csv.exists():
        print(
            "error: annotation CSVs not found at "
            f"{args.videos_csv} / {args.reps_csv}",
            file=sys.stderr,
        )
        return 2

    videos = _read_videos_csv(args.videos_csv)
    reps = _read_reps_csv(args.reps_csv)
    if not reps:
        print(
            "No rep annotations found — compute_rep_stats is a no-op. "
            "Fill in data/annotations/reps.csv and re-run.",
            file=sys.stderr,
        )
        write_stats_csv([], args.out)
        return 0

    stats = list(iter_rep_stats(videos, reps, args.keypoints_dir))
    written = write_stats_csv(stats, args.out)
    print(f"Wrote {written} rep rows -> {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


# Re-export for tests / REPL convenience.
__all__ = [
    "RepRow",
    "RepStats",
    "VideoRow",
    "build_parser",
    "compute_rep_stats",
    "elbow_angle_for_arm",
    "iter_rep_stats",
    "main",
    "torso_length",
    "write_stats_csv",
]
