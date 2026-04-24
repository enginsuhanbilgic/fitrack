"""BlazePose 33-landmark indices — Python mirror of app/lib/models/landmark_types.dart.

MediaPipe Pose Landmarker and ML Kit Pose share the same BlazePose index schema,
so these constants are valid for both. Any reordering in the Dart source must be
mirrored here in the same commit.
"""

from __future__ import annotations

from typing import Final


# --- Face ---
NOSE: Final[int] = 0
LEFT_EYE_INNER: Final[int] = 1
LEFT_EYE: Final[int] = 2
LEFT_EYE_OUTER: Final[int] = 3
RIGHT_EYE_INNER: Final[int] = 4
RIGHT_EYE: Final[int] = 5
RIGHT_EYE_OUTER: Final[int] = 6
LEFT_EAR: Final[int] = 7
RIGHT_EAR: Final[int] = 8
LEFT_MOUTH: Final[int] = 9
RIGHT_MOUTH: Final[int] = 10

# --- Upper body ---
LEFT_SHOULDER: Final[int] = 11
RIGHT_SHOULDER: Final[int] = 12
LEFT_ELBOW: Final[int] = 13
RIGHT_ELBOW: Final[int] = 14
LEFT_WRIST: Final[int] = 15
RIGHT_WRIST: Final[int] = 16
LEFT_PINKY: Final[int] = 17
RIGHT_PINKY: Final[int] = 18
LEFT_INDEX: Final[int] = 19
RIGHT_INDEX: Final[int] = 20
LEFT_THUMB: Final[int] = 21
RIGHT_THUMB: Final[int] = 22

# --- Hips / legs ---
LEFT_HIP: Final[int] = 23
RIGHT_HIP: Final[int] = 24
LEFT_KNEE: Final[int] = 25
RIGHT_KNEE: Final[int] = 26
LEFT_ANKLE: Final[int] = 27
RIGHT_ANKLE: Final[int] = 28
LEFT_HEEL: Final[int] = 29
RIGHT_HEEL: Final[int] = 30
LEFT_FOOT_INDEX: Final[int] = 31
RIGHT_FOOT_INDEX: Final[int] = 32

LANDMARK_COUNT: Final[int] = 33


# Triplets used for each exercise's primary joint angle. Mirrors the joint
# selections in rep_counter.dart _computeAngle.
CURL_LEFT_TRIPLET: Final[tuple[int, int, int]] = (
    LEFT_SHOULDER,
    LEFT_ELBOW,
    LEFT_WRIST,
)
CURL_RIGHT_TRIPLET: Final[tuple[int, int, int]] = (
    RIGHT_SHOULDER,
    RIGHT_ELBOW,
    RIGHT_WRIST,
)
SQUAT_LEFT_TRIPLET: Final[tuple[int, int, int]] = (
    LEFT_HIP,
    LEFT_KNEE,
    LEFT_ANKLE,
)
SQUAT_RIGHT_TRIPLET: Final[tuple[int, int, int]] = (
    RIGHT_HIP,
    RIGHT_KNEE,
    RIGHT_ANKLE,
)
PUSHUP_LEFT_TRIPLET: Final[tuple[int, int, int]] = (
    LEFT_SHOULDER,
    LEFT_ELBOW,
    LEFT_WRIST,
)
PUSHUP_RIGHT_TRIPLET: Final[tuple[int, int, int]] = (
    RIGHT_SHOULDER,
    RIGHT_ELBOW,
    RIGHT_WRIST,
)
