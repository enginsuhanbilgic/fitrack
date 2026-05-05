"""Phase B (auto) — Auto-detect rep boundaries from keypoint JSONLs.

Reads `data/keypoints/{clip_id}.jsonl` + `data/annotations/videos.csv` and
writes `data/annotations/reps.csv` with one row per detected rep:

    clip_id, rep_idx, start_frame, peak_frame, end_frame, quality

Rep detection walks the smoothed elbow-angle series and identifies
rest-peak-rest triples: local maxima (arm extended, ~160°) bracketing a
local minimum (arm flexed, ~70°). Gates mirror the shipping Dart
`rep_boundary_detector.dart` so offline annotations match on-device FSM
behaviour:

  * Minimum excursion per rep >= `kCalibrationMinExcursion` (40°).
  * Minimum dwell between direction flips >= `kRepBoundaryMinDwellFrames`
    (8 frames).

Quality is inherited from `videos.intended_quality`. If a clip omits that
column the rep rows get an empty quality — the annotator must fill them in
before Phase C will use them.

Usage:
    python scripts/phase_b_auto_annotate.py
    python scripts/phase_b_auto_annotate.py --videos custom_videos.csv --out custom_reps.csv
    python scripts/phase_b_auto_annotate.py --clip-id curl_001
    python scripts/phase_b_auto_annotate.py --review  # prints per-clip summary
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from scripts.angle_utils import smooth_angle_series
from scripts.compute_rep_stats import VideoRow, _read_videos_csv
from scripts.jsonl_io import FrameSample, load_frames
from scripts.landmark_indices import (
    CURL_LEFT_TRIPLET,
    CURL_RIGHT_TRIPLET,
)
from scripts.angle_utils import angle_deg

REPO_ROOT = Path(__file__).resolve().parents[1]
KEYPOINTS_DIR = REPO_ROOT / "data" / "keypoints"
ANNOTATIONS_DIR = REPO_ROOT / "data" / "annotations"

DEFAULT_VIDEOS = ANNOTATIONS_DIR / "videos.csv"
DEFAULT_REPS_OUT = ANNOTATIONS_DIR / "reps.csv"

# ---------------------------------------------------------------------------
# Detection gates — mirror the Dart rep_boundary_detector constants.
# ---------------------------------------------------------------------------

# app/lib/core/constants.dart :: kCalibrationMinExcursion
MIN_EXCURSION_DEG: float = 40.0

# app/lib/core/constants.dart :: kRepBoundaryMinDwellFrames
MIN_DWELL_FRAMES: int = 8

VALID_QUALITIES = {"good", "bad_swing", "bad_partial_rom", "bad_speed"}


# ---------------------------------------------------------------------------
# Output row
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DetectedRep:
    clip_id: str
    rep_idx: int
    start_frame: int
    peak_frame: int
    end_frame: int
    quality: str


# ---------------------------------------------------------------------------
# Angle extraction for a clip
# ---------------------------------------------------------------------------


def _elbow_angle(sample: FrameSample, arm: str) -> Optional[float]:
    """Elbow angle in degrees for the requested arm.

    For `arm == "both"` the mean of the two sides is used when both are
    valid, falling back to whichever single side resolved. This mirrors
    `compute_rep_stats.elbow_angle_for_arm`.
    """
    left = angle_deg(
        sample.landmark(CURL_LEFT_TRIPLET[0]),
        sample.landmark(CURL_LEFT_TRIPLET[1]),
        sample.landmark(CURL_LEFT_TRIPLET[2]),
    )
    right = angle_deg(
        sample.landmark(CURL_RIGHT_TRIPLET[0]),
        sample.landmark(CURL_RIGHT_TRIPLET[1]),
        sample.landmark(CURL_RIGHT_TRIPLET[2]),
    )
    if arm == "left":
        return left
    if arm == "right":
        return right
    if left is not None and right is not None:
        return (left + right) / 2.0
    return left if left is not None else right


def angle_series(frames: list[FrameSample], arm: str) -> list[Optional[float]]:
    """Smoothed elbow-angle series for a clip. None where landmarks miss the gate."""
    raw = [_elbow_angle(f, arm) for f in frames]
    return smooth_angle_series(raw)


# ---------------------------------------------------------------------------
# Rep detection — pure function on the smoothed angle series.
# ---------------------------------------------------------------------------


def detect_reps(
    angles: list[Optional[float]],
    *,
    min_excursion: float = MIN_EXCURSION_DEG,
    min_dwell_frames: int = MIN_DWELL_FRAMES,
) -> list[tuple[int, int, int]]:
    """Find `(start_frame, peak_frame, end_frame)` triples in the series.

    Algorithm:

      1. Walk the series tracking current direction (ascending vs descending)
         using a strict comparison gated by `min_dwell_frames` — matches the
         Dart boundary detector's chatter + dwell guard combined.
      2. When direction flips from descending → ascending we have a candidate
         peak. We pair it with the nearest preceding ascending→descending
         flip (the `start`) and wait for the next descending→ascending flip
         (the `end`).
      3. Reject candidates where `max(angleAtStart, angleAtEnd) - minPeak <
         min_excursion` — the rep didn't travel enough.

    None values (low-confidence frames) are treated as "hold last direction";
    they never create a flip. The first pose frame seeds direction.
    """
    if not angles:
        return []

    # First pass: compact to (frame_index, angle) pairs for defined frames
    # and pick out local extrema with the dwell guard.
    points: list[tuple[int, float]] = [
        (i, a) for i, a in enumerate(angles) if a is not None
    ]
    if len(points) < 2:
        return []

    # direction: +1 ascending (angle growing -> arm extending),
    #            -1 descending (angle shrinking -> arm flexing)
    # Sign convention matches the Dart boundary detector.
    extrema: list[tuple[int, float, int]] = []  # (frame, angle, kind: +1 max / -1 min)

    direction = 0
    last_flip_frame = points[0][0]
    pending_kind = 0  # direction we'd record if dwell passes
    pending_frame = points[0][0]
    pending_angle = points[0][1]

    for idx in range(1, len(points)):
        frame, angle = points[idx]
        prev_frame, prev_angle = points[idx - 1]
        if angle > prev_angle:
            new_dir = +1
        elif angle < prev_angle:
            new_dir = -1
        else:
            new_dir = direction  # plateau — inherit

        if direction == 0:
            direction = new_dir
            pending_frame = prev_frame
            pending_angle = prev_angle
            # Kind of the first extremum is opposite of the first move direction:
            # first move up  => we started at a local min
            # first move down => we started at a local max
            pending_kind = -1 if new_dir == +1 else +1
            last_flip_frame = prev_frame
            continue

        if new_dir != 0 and new_dir != direction:
            # A flip candidate — the extremum is the previous point.
            flip_frame = prev_frame
            flip_angle = prev_angle
            flip_kind = +1 if direction == +1 else -1
            # Dwell: require the streak of the prior direction to be >= min_dwell.
            if flip_frame - last_flip_frame >= min_dwell_frames:
                # Record the previous pending extremum — it's now confirmed.
                extrema.append((pending_frame, pending_angle, pending_kind))
                pending_frame = flip_frame
                pending_angle = flip_angle
                pending_kind = flip_kind
                last_flip_frame = flip_frame
                direction = new_dir
            # else: ignore the flip; keep walking — chatter.

    # Close out: record the last confirmed pending extremum, then — if the
    # final direction streak is long enough — record a terminal extremum at
    # the last frame so trailing (min,max) or (max,min) pairs surface.
    extrema.append((pending_frame, pending_angle, pending_kind))
    if direction != 0:
        last_frame, last_angle = points[-1]
        terminal_kind = +1 if direction == +1 else -1
        if (
            last_frame - last_flip_frame >= min_dwell_frames
            and last_frame != pending_frame
        ):
            extrema.append((last_frame, last_angle, terminal_kind))

    # Walk extrema for (max, min, max) triples = (start, peak, end).
    reps: list[tuple[int, int, int]] = []
    i = 0
    while i + 2 < len(extrema):
        s_frame, s_angle, s_kind = extrema[i]
        p_frame, p_angle, p_kind = extrema[i + 1]
        e_frame, e_angle, e_kind = extrema[i + 2]
        if s_kind == +1 and p_kind == -1 and e_kind == +1:
            excursion = max(s_angle, e_angle) - p_angle
            if excursion >= min_excursion:
                reps.append((s_frame, p_frame, e_frame))
                i += 2  # end of this rep is start of the next
                continue
        i += 1

    return reps


# ---------------------------------------------------------------------------
# Clip → rep rows
# ---------------------------------------------------------------------------


def detect_for_clip(
    video: VideoRow, frames: list[FrameSample]
) -> list[DetectedRep]:
    angles = angle_series(frames, video.arm)
    raw = detect_reps(angles)
    quality = video.intended_quality if video.intended_quality in VALID_QUALITIES else ""
    out: list[DetectedRep] = []
    for rep_idx, (start, peak, end) in enumerate(raw):
        out.append(
            DetectedRep(
                clip_id=video.clip_id,
                rep_idx=rep_idx,
                start_frame=start,
                peak_frame=peak,
                end_frame=end,
                quality=quality,
            )
        )
    return out


# ---------------------------------------------------------------------------
# CSV writing
# ---------------------------------------------------------------------------


def write_reps_csv(path: Path, rows: list[DetectedRep]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["clip_id", "rep_idx", "start_frame", "peak_frame", "end_frame", "quality"]
        )
        for r in rows:
            writer.writerow(
                [
                    r.clip_id,
                    r.rep_idx,
                    r.start_frame,
                    r.peak_frame,
                    r.end_frame,
                    r.quality,
                ]
            )


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--videos", type=Path, default=DEFAULT_VIDEOS)
    parser.add_argument("--out", type=Path, default=DEFAULT_REPS_OUT)
    parser.add_argument("--keypoints-dir", type=Path, default=KEYPOINTS_DIR)
    parser.add_argument(
        "--clip-id",
        type=str,
        default=None,
        help="Only process the named clip (useful for iterating on one recording).",
    )
    parser.add_argument(
        "--review",
        action="store_true",
        help="Print a per-clip rep-count summary to stderr after writing.",
    )
    args = parser.parse_args(argv)

    if not args.videos.exists():
        print(f"videos.csv not found at {args.videos}", file=sys.stderr)
        return 2

    videos = _read_videos_csv(args.videos)
    if args.clip_id is not None:
        if args.clip_id not in videos:
            print(f"clip_id '{args.clip_id}' not in {args.videos}", file=sys.stderr)
            return 2
        videos = {args.clip_id: videos[args.clip_id]}

    all_rows: list[DetectedRep] = []
    summary: list[tuple[str, str, int]] = []  # (clip_id, intended_quality, count)
    for clip_id, video in videos.items():
        jsonl_path = args.keypoints_dir / f"{clip_id}.jsonl"
        if not jsonl_path.exists():
            print(
                f"[skip] keypoints missing for {clip_id}: {jsonl_path}",
                file=sys.stderr,
            )
            continue
        frames = load_frames(jsonl_path)
        rows = detect_for_clip(video, frames)
        all_rows.extend(rows)
        summary.append((clip_id, video.intended_quality or "(unset)", len(rows)))

    write_reps_csv(args.out, all_rows)
    print(
        f"wrote {len(all_rows)} rep rows across {len(summary)} clips to {args.out}",
        file=sys.stderr,
    )

    if args.review:
        print("\nper-clip summary:", file=sys.stderr)
        for clip_id, q, count in summary:
            print(f"  {clip_id:<30} intended={q:<18} detected={count}", file=sys.stderr)

    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(_main(sys.argv[1:]))
