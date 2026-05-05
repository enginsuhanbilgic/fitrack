"""Phase B — Video -> MediaPipe keypoints JSONL.

Reads a video file frame-by-frame, runs MediaPipe Pose Landmarker, and emits
one JSON line per frame to data/keypoints/{clip_id}.jsonl.

Usage:
    python scripts/extract_keypoints.py --video data/videos/clip_042.mp4
    python scripts/extract_keypoints.py --video data/videos/clip_042.mp4 --out custom.jsonl
    python scripts/extract_keypoints.py --all

JSONL schema (one object per line):
    {
      "frame": 42,
      "t_ms": 1400,
      "landmarks": [
        {"x": 0.51, "y": 0.32, "z": -0.10, "v": 0.98},
        ... 33 items total, ordered by BlazePose index
      ]
    }

Missing-person frames emit an empty landmarks array. Downstream scripts treat
this the same as a low-confidence frame.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional

# MediaPipe and OpenCV are optional at import time so the module can be loaded
# in environments that only want the helpers (e.g. pytest). The real CLI
# entrypoints raise a clear error if they're missing.
try:
    import cv2  # type: ignore
except ImportError:  # pragma: no cover - import guard
    cv2 = None  # type: ignore

try:
    import mediapipe as mp  # type: ignore
except ImportError:  # pragma: no cover - import guard
    mp = None  # type: ignore


REPO_ROOT = Path(__file__).resolve().parents[1]
VIDEOS_DIR = REPO_ROOT / "data" / "videos"
KEYPOINTS_DIR = REPO_ROOT / "data" / "keypoints"

# Video extensions we know how to read.
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi"}


@dataclass(frozen=True)
class FrameRecord:
    """One row of the output JSONL — deliberately flat and JSON-serialisable."""

    frame: int
    t_ms: int
    landmarks: list[dict[str, float]]

    def to_json_line(self) -> str:
        # `separators` disables whitespace so one line = one record on disk.
        return json.dumps(
            {
                "frame": self.frame,
                "t_ms": self.t_ms,
                "landmarks": self.landmarks,
            },
            separators=(",", ":"),
        )


def _require_runtime_deps() -> None:
    """Fail loudly if MediaPipe / OpenCV aren't installed — only on real runs."""
    missing = []
    if cv2 is None:
        missing.append("opencv-python")
    if mp is None:
        missing.append("mediapipe")
    if missing:
        raise RuntimeError(
            "Missing required runtime dependency: "
            + ", ".join(missing)
            + "\nInstall with: pip install -r requirements.txt"
        )


def iter_video_frames(
    video_path: Path,
) -> Iterator[tuple[int, int, "cv2.Mat"]]:  # type: ignore[name-defined]
    """Yield (frame_index, t_ms, bgr_image) tuples for the whole video.

    OpenCV returns BGR; MediaPipe wants RGB. Conversion happens at the caller
    because we want the raw OpenCV frame for any downstream debugging too.
    """
    _require_runtime_deps()
    assert cv2 is not None  # for type-checkers
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        raise RuntimeError(f"Could not open video: {video_path}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    try:
        idx = 0
        while True:
            ok, frame_bgr = cap.read()
            if not ok:
                break
            t_ms = int(round(idx * 1000.0 / fps))
            yield idx, t_ms, frame_bgr
            idx += 1
    finally:
        cap.release()


def _landmarks_to_dicts(
    landmarks,  # mp.solutions.pose landmark list or None
) -> list[dict[str, float]]:
    """Flatten a MediaPipe NormalizedLandmarkList into our JSONL payload.

    MediaPipe exposes `x`, `y`, `z`, `visibility` on each landmark; the shipping
    app uses `confidence` for the visibility field. We rename on write so the
    on-device pipeline and this file speak the same language.
    """
    if landmarks is None:
        return []
    # New API (0.10.x tasks) returns a list of NormalizedLandmark directly.
    # Old API returned a NormalizedLandmarkList with a `.landmark` attribute.
    iterable = landmarks if isinstance(landmarks, list) else landmarks.landmark
    out: list[dict[str, float]] = []
    for lm in iterable:
        out.append(
            {
                "x": round(float(lm.x), 6),
                "y": round(float(lm.y), 6),
                "z": round(float(lm.z), 6),
                "v": round(float(lm.visibility), 6),
            }
        )
    return out


def extract_video(
    video_path: Path,
    output_path: Path,
    model_complexity: int = 2,
    verbose: bool = True,
) -> int:
    """Run MediaPipe on `video_path` and write JSONL to `output_path`.

    `model_complexity=2` uses the heavy variant (highest accuracy, offline-only).
    Returns the number of frames written.
    """
    _require_runtime_deps()
    assert cv2 is not None and mp is not None  # for type-checkers

    output_path.parent.mkdir(parents=True, exist_ok=True)

    # MediaPipe 0.10.x uses tasks API
    # Download the model from Google's official source
    from mediapipe.tasks.python import vision
    from mediapipe.tasks.python.core import base_options as base_options_module
    import urllib.request
    import tempfile
    import ssl

    # Create temp directory for model
    model_cache = Path.home() / ".cache" / "mediapipe"
    model_cache.mkdir(parents=True, exist_ok=True)
    model_path = model_cache / "pose_landmarker_heavy.tflite"

    if not model_path.exists():
        print(f"Downloading pose model (~30MB)...", file=sys.stderr)
        url = "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_heavy/float16/latest/pose_landmarker_heavy.task"
        try:
            # Bypass SSL cert issues if needed
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE

            with urllib.request.urlopen(url, context=ctx) as response:
                with open(model_path, 'wb') as out_file:
                    out_file.write(response.read())
            print(f"Downloaded to {model_path}", file=sys.stderr)
        except Exception as e:
            print(f"Download failed: {e}", file=sys.stderr)
            raise RuntimeError(
                f"Could not download pose model. Please download manually:\n"
                f"curl -o {model_path} {url}"
            )

    # Create the pose landmarker with the downloaded model
    base_options = base_options_module.BaseOptions(model_asset_path=str(model_path))
    options = vision.PoseLandmarkerOptions(
        base_options=base_options,
        output_segmentation_masks=False,
    )
    detector = vision.PoseLandmarker.create_from_options(options)

    frames_written = 0
    start = time.time()
    try:
        with output_path.open("w", encoding="utf-8") as sink:
            for idx, t_ms, frame_bgr in iter_video_frames(video_path):
                frame_rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
                mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame_rgb)
                result = detector.detect(mp_image)
                pose_lm = result.pose_landmarks[0] if result.pose_landmarks else None
                landmarks = _landmarks_to_dicts(pose_lm)

                record = FrameRecord(frame=idx, t_ms=t_ms, landmarks=landmarks)
                sink.write(record.to_json_line())
                sink.write("\n")
                frames_written += 1
                if verbose and frames_written % 60 == 0:
                    elapsed = time.time() - start
                    fps_avg = frames_written / max(elapsed, 1e-6)
                    print(
                        f"  {video_path.name}: {frames_written} frames "
                        f"({fps_avg:.1f} fps avg)",
                        file=sys.stderr,
                    )
    finally:
        detector.close()

    return frames_written


def default_output_path(video_path: Path) -> Path:
    """data/videos/clip_042.mp4 -> data/keypoints/clip_042.jsonl"""
    return KEYPOINTS_DIR / f"{video_path.stem}.jsonl"


def discover_videos() -> list[Path]:
    """Every file under data/videos/ with a known video extension."""
    if not VIDEOS_DIR.exists():
        return []
    return sorted(
        p
        for p in VIDEOS_DIR.iterdir()
        if p.is_file() and p.suffix.lower() in VIDEO_EXTENSIONS
    )


def is_stale(video_path: Path, output_path: Path) -> bool:
    """True if the output doesn't exist or is older than the video."""
    if not output_path.exists():
        return True
    return output_path.stat().st_mtime < video_path.stat().st_mtime


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run MediaPipe Pose on one or all videos and write keypoints JSONL."
        )
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--video",
        type=Path,
        help="Path to a single video. If --out is omitted, the default name is used.",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Process every video under data/videos/ whose output is missing or stale.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Override output path (ignored with --all).",
    )
    parser.add_argument(
        "--model-complexity",
        type=int,
        default=2,
        choices=[0, 1, 2],
        help="MediaPipe Pose model complexity. 2 = heavy (recommended offline).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Re-extract even if the output exists and is newer than the video.",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="Suppress per-clip progress output.",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    verbose = not args.quiet

    if args.video is not None:
        video_path: Path = args.video
        if not video_path.exists():
            print(f"error: video not found: {video_path}", file=sys.stderr)
            return 2
        out_path = args.out or default_output_path(video_path)
        if verbose:
            print(f"Extracting {video_path.name} -> {out_path}", file=sys.stderr)
        frames = extract_video(
            video_path,
            out_path,
            model_complexity=args.model_complexity,
            verbose=verbose,
        )
        if verbose:
            print(f"  done: {frames} frames", file=sys.stderr)
        return 0

    # --all mode
    videos = discover_videos()
    if not videos:
        print(
            f"No videos found in {VIDEOS_DIR}. "
            "Drop .mp4 files there and re-run.",
            file=sys.stderr,
        )
        return 0
    todo = [
        v for v in videos if args.force or is_stale(v, default_output_path(v))
    ]
    skipped = len(videos) - len(todo)
    if verbose:
        print(
            f"{len(videos)} video(s) total, {len(todo)} to process, "
            f"{skipped} up to date.",
            file=sys.stderr,
        )
    for v in todo:
        out_path = default_output_path(v)
        if verbose:
            print(f"Extracting {v.name} -> {out_path.name}", file=sys.stderr)
        frames = extract_video(
            v,
            out_path,
            model_complexity=args.model_complexity,
            verbose=verbose,
        )
        if verbose:
            print(f"  done: {frames} frames", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
