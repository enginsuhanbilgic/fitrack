"""Pure math helpers ported verbatim from app/lib/engine/angle_utils.dart.

The Dart file is the single source of truth. Any change here must be mirrored
there (and vice versa) in the same commit, with tests updated.

Visibility thresholds match MediaPipe's `visibility` field and mirror the Dart
`kMinLandmarkConfidence = 0.4` constant defined in app/lib/core/constants.dart.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional


# Mirrors kMinLandmarkConfidence in app/lib/core/constants.dart.
MIN_LANDMARK_CONFIDENCE: float = 0.4

# Mirrors RepCounter._smoothWindow in app/lib/engine/rep_counter.dart.
SMOOTH_WINDOW: int = 3


@dataclass(frozen=True)
class Landmark:
    """Mirrors the fields the Dart `angleDeg` reads from `PoseLandmark`.

    `x` and `y` are normalized (0..1) image coordinates — same convention as
    ML Kit Pose and MediaPipe Pose. `confidence` is the landmark's visibility
    score in [0, 1].
    """

    x: float
    y: float
    confidence: float


def angle_deg(
    a: Optional[Landmark],
    b: Optional[Landmark],
    c: Optional[Landmark],
) -> Optional[float]:
    """Angle at joint B formed by segments BA and BC, in degrees [0..180].

    Verbatim port of `angleDeg` in angle_utils.dart. Returns None when any
    input is missing, any confidence is below the gate, or either segment has
    zero length (would cause division by zero).
    """
    if a is None or b is None or c is None:
        return None
    if (
        a.confidence < MIN_LANDMARK_CONFIDENCE
        or b.confidence < MIN_LANDMARK_CONFIDENCE
        or c.confidence < MIN_LANDMARK_CONFIDENCE
    ):
        return None

    bax = a.x - b.x
    bay = a.y - b.y
    bcx = c.x - b.x
    bcy = c.y - b.y

    dot = bax * bcx + bay * bcy
    mag1 = math.sqrt(bax * bax + bay * bay)
    mag2 = math.sqrt(bcx * bcx + bcy * bcy)
    if mag1 == 0 or mag2 == 0:
        return None

    cos_theta = max(-1.0, min(1.0, dot / (mag1 * mag2)))
    return math.acos(cos_theta) * 180.0 / math.pi


def smooth_angle_series(angles: list[Optional[float]]) -> list[Optional[float]]:
    """Apply the shipping FSM's 3-frame moving-average smoother.

    Mirrors RepCounter.update in rep_counter.dart:

        _angleBuffer.add(angle);
        if (_angleBuffer.length > _smoothWindow) _angleBuffer.removeAt(0);
        final smoothed = _angleBuffer.reduce((a, b) => a + b) / _angleBuffer.length;

    The window *grows* from 1 up to SMOOTH_WINDOW before sliding. That means
    the first two outputs are averaged over fewer samples, not the most-recent
    3. This is load-bearing — replacing with a fixed-width rolling mean would
    desynchronise the first two frames from the real device behaviour.

    None inputs (low-confidence frames) are passed through unchanged; they
    neither enter the buffer nor reset it — matching the Dart early-return at
    `if (angle == null) return _snapshot();`.
    """
    buffer: list[float] = []
    out: list[Optional[float]] = []
    for angle in angles:
        if angle is None:
            out.append(None)
            continue
        buffer.append(angle)
        if len(buffer) > SMOOTH_WINDOW:
            buffer.pop(0)
        out.append(sum(buffer) / len(buffer))
    return out


def vertical_dist(
    a: Optional[Landmark], b: Optional[Landmark]
) -> Optional[float]:
    """Vertical distance between two landmarks. Torso-length helper."""
    if a is None or b is None:
        return None
    return abs(a.y - b.y)


def angle_to_vertical(
    a: Optional[Landmark], b: Optional[Landmark]
) -> Optional[float]:
    """Angle of segment (a -> b) relative to vertical, in degrees [0..90]."""
    if a is None or b is None:
        return None
    dx = abs(b.x - a.x)
    dy = abs(b.y - a.y)
    if dy == 0:
        return 90.0
    return math.atan2(dx, dy) * 180.0 / math.pi
