"""Shared helpers for reading the keypoints JSONL format.

The JSONL files produced by extract_keypoints.py are the one committed
artifact that every downstream script depends on, so the readers live in
one place. If the on-disk schema ever changes, it must change here too.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Optional

from scripts.angle_utils import Landmark
from scripts.landmark_indices import LANDMARK_COUNT


@dataclass(frozen=True)
class FrameSample:
    """One decoded row from a JSONL file."""

    frame: int
    t_ms: int
    landmarks: list[Optional[Landmark]]

    def landmark(self, index: int) -> Optional[Landmark]:
        """Return the landmark at `index` or None if the frame has no person."""
        if not self.landmarks:
            return None
        if index < 0 or index >= len(self.landmarks):
            return None
        return self.landmarks[index]


def _decode_landmarks(raw: list[dict]) -> list[Optional[Landmark]]:
    """Convert the on-disk {x, y, z, v} dicts into angle_utils.Landmark.

    Returns an empty list when the source list is empty (missing person).
    Any row whose list isn't 33 items is rejected loudly because percentile
    derivation assumes BlazePose's fixed schema.
    """
    if not raw:
        return []
    if len(raw) != LANDMARK_COUNT:
        raise ValueError(
            f"Expected {LANDMARK_COUNT} landmarks per frame, got {len(raw)}."
        )
    out: list[Optional[Landmark]] = []
    for item in raw:
        out.append(
            Landmark(
                x=float(item["x"]),
                y=float(item["y"]),
                confidence=float(item["v"]),
            )
        )
    return out


def iter_frames(jsonl_path: Path) -> Iterator[FrameSample]:
    """Stream a JSONL file one frame at a time. Skips blank lines."""
    with jsonl_path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            yield FrameSample(
                frame=int(obj["frame"]),
                t_ms=int(obj["t_ms"]),
                landmarks=_decode_landmarks(obj.get("landmarks", [])),
            )


def load_frames(jsonl_path: Path) -> list[FrameSample]:
    """Eagerly load the whole file. Convenient for per-clip windowing."""
    return list(iter_frames(jsonl_path))
