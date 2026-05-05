"""Known-answer tests for the Python port of angle_utils.dart.

Each test maps to a concrete case that would catch a specific regression if
the port ever drifts from the Dart source of truth.
"""

from __future__ import annotations

import math

import pytest

from scripts.angle_utils import (
    MIN_LANDMARK_CONFIDENCE,
    SMOOTH_WINDOW,
    Landmark,
    angle_deg,
    angle_to_vertical,
    smooth_angle_series,
    vertical_dist,
)


# ---------------------------------------------------------------------------
# angle_deg
# ---------------------------------------------------------------------------


def _lm(x: float, y: float, conf: float = 1.0) -> Landmark:
    return Landmark(x=x, y=y, confidence=conf)


def test_angle_deg_right_angle():
    """Elbow at origin, shoulder up, wrist right -> exactly 90 deg."""
    shoulder = _lm(0.0, -1.0)
    elbow = _lm(0.0, 0.0)
    wrist = _lm(1.0, 0.0)
    assert angle_deg(shoulder, elbow, wrist) == pytest.approx(90.0)


def test_angle_deg_straight_arm_is_180():
    """Colinear points -> 180 deg (full elbow extension)."""
    shoulder = _lm(0.0, 0.0)
    elbow = _lm(1.0, 0.0)
    wrist = _lm(2.0, 0.0)
    assert angle_deg(shoulder, elbow, wrist) == pytest.approx(180.0)


def test_angle_deg_zero_when_superimposed():
    """Shoulder and wrist at the same point relative to elbow -> 0 deg."""
    shoulder = _lm(1.0, 0.0)
    elbow = _lm(0.0, 0.0)
    wrist = _lm(1.0, 0.0)
    assert angle_deg(shoulder, elbow, wrist) == pytest.approx(0.0)


def test_angle_deg_obtuse_matches_manual_trig():
    """Vertices S(0,0), E(1,0), W(1.5, sqrt(3)/2) -> BA=(-1,0), BC=(0.5, sqrt(3)/2).

    Both magnitudes are 1, dot product is -0.5, so cos(theta) = -0.5 -> 120 deg.
    Hand-computed; verifies the sign of the dot product is handled correctly.
    """
    shoulder = _lm(0.0, 0.0)
    elbow = _lm(1.0, 0.0)
    wrist = _lm(1.5, math.sqrt(3) / 2)
    assert angle_deg(shoulder, elbow, wrist) == pytest.approx(120.0, abs=1e-6)


def test_angle_deg_acute_matches_manual_trig():
    """Vertices S(0,0), E(1,0), W(0.5, sqrt(3)/2) -> BA=(-1,0), BC=(-0.5, sqrt(3)/2).

    Both magnitudes are 1, dot product is +0.5, so cos(theta) = 0.5 -> 60 deg.
    Symmetric partner of the 120 deg test — catches sign bugs in either direction.
    """
    shoulder = _lm(0.0, 0.0)
    elbow = _lm(1.0, 0.0)
    wrist = _lm(0.5, math.sqrt(3) / 2)
    assert angle_deg(shoulder, elbow, wrist) == pytest.approx(60.0, abs=1e-6)


def test_angle_deg_none_when_any_landmark_missing():
    a = _lm(0.0, 0.0)
    b = _lm(1.0, 0.0)
    assert angle_deg(None, a, b) is None
    assert angle_deg(a, None, b) is None
    assert angle_deg(a, b, None) is None


def test_angle_deg_none_when_any_confidence_below_gate():
    low = MIN_LANDMARK_CONFIDENCE - 0.01
    ok = MIN_LANDMARK_CONFIDENCE  # inclusive gate in Dart: `< threshold` => reject
    a_low = _lm(0.0, 0.0, conf=low)
    b_ok = _lm(1.0, 0.0, conf=ok)
    c_ok = _lm(2.0, 0.0, conf=ok)
    assert angle_deg(a_low, b_ok, c_ok) is None
    assert angle_deg(b_ok, a_low, c_ok) is None
    assert angle_deg(b_ok, c_ok, a_low) is None


def test_angle_deg_accepts_exact_threshold_confidence():
    """Dart uses `confidence < kMinLandmarkConfidence` — exact threshold passes."""
    at_gate = MIN_LANDMARK_CONFIDENCE
    shoulder = _lm(0.0, -1.0, conf=at_gate)
    elbow = _lm(0.0, 0.0, conf=at_gate)
    wrist = _lm(1.0, 0.0, conf=at_gate)
    result = angle_deg(shoulder, elbow, wrist)
    assert result is not None
    assert result == pytest.approx(90.0)


def test_angle_deg_none_for_zero_length_segment():
    """Two superimposed landmarks produce a zero-magnitude vector -> None."""
    zero = _lm(0.5, 0.5)
    other = _lm(1.0, 0.5)
    # a == b -> BA has zero magnitude
    assert angle_deg(zero, zero, other) is None
    # b == c -> BC has zero magnitude
    assert angle_deg(other, zero, zero) is None


def test_angle_deg_handles_near_colinear_without_nan():
    """Floating-point drift can push cos_theta past +/- 1; the clamp must save us."""
    shoulder = _lm(0.0, 0.0)
    elbow = _lm(1.0, 0.0)
    # Very nearly colinear but not exactly — no NaN allowed.
    wrist = _lm(2.0, 1e-15)
    result = angle_deg(shoulder, elbow, wrist)
    assert result is not None
    assert not math.isnan(result)
    assert result == pytest.approx(180.0, abs=1e-5)


# ---------------------------------------------------------------------------
# smooth_angle_series
# ---------------------------------------------------------------------------


def test_smooth_growing_window_matches_dart_behaviour():
    """First two outputs average fewer-than-3 samples (growing window)."""
    # Input: 10, 20, 30, 40, 50
    # Dart buffer walk:
    #   after 10 -> [10],      mean = 10
    #   after 20 -> [10,20],   mean = 15
    #   after 30 -> [10,20,30],mean = 20
    #   after 40 -> [20,30,40],mean = 30   (buffer sizes cap at 3)
    #   after 50 -> [30,40,50],mean = 40
    assert smooth_angle_series([10.0, 20.0, 30.0, 40.0, 50.0]) == [
        10.0,
        15.0,
        20.0,
        30.0,
        40.0,
    ]


def test_smooth_window_constant_is_three():
    """Contract check: Dart uses _smoothWindow = 3. If this changes we want a loud failure."""
    assert SMOOTH_WINDOW == 3


def test_smooth_passes_none_through_without_touching_buffer():
    """Low-confidence frames (None) must not enter the buffer nor reset it.

    Matches the Dart early-return `if (angle == null) return _snapshot();`:
    the buffer keeps its previous state and the next real frame resumes
    smoothing as if the None never happened.
    """
    # Buffer after 10,20 is [10,20]. Then None does nothing. Then 30 produces
    # mean(10,20,30) = 20 — NOT mean(20,30) = 25 which would be wrong.
    out = smooth_angle_series([10.0, 20.0, None, 30.0])
    assert out == [10.0, 15.0, None, 20.0]


def test_smooth_empty_input():
    assert smooth_angle_series([]) == []


def test_smooth_all_none():
    assert smooth_angle_series([None, None, None]) == [None, None, None]


# ---------------------------------------------------------------------------
# vertical_dist / angle_to_vertical
# ---------------------------------------------------------------------------


def test_vertical_dist_is_absolute():
    assert vertical_dist(_lm(0.0, 0.3), _lm(0.0, 0.9)) == pytest.approx(0.6)
    assert vertical_dist(_lm(0.0, 0.9), _lm(0.0, 0.3)) == pytest.approx(0.6)


def test_vertical_dist_none_on_missing():
    assert vertical_dist(None, _lm(0.0, 0.0)) is None
    assert vertical_dist(_lm(0.0, 0.0), None) is None


def test_angle_to_vertical_pure_vertical_segment_is_zero():
    assert angle_to_vertical(_lm(0.5, 0.1), _lm(0.5, 0.9)) == pytest.approx(0.0)


def test_angle_to_vertical_pure_horizontal_segment_is_ninety():
    assert angle_to_vertical(_lm(0.1, 0.5), _lm(0.9, 0.5)) == pytest.approx(90.0)


def test_angle_to_vertical_forty_five_degrees():
    """dx == dy (after abs) -> 45 deg."""
    assert angle_to_vertical(_lm(0.0, 0.0), _lm(0.3, 0.3)) == pytest.approx(45.0)
