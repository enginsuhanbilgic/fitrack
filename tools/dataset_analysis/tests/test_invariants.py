"""Tests for `scripts.invariants.enforce_ordering` — the shared clamp that
the push-up rewrite uses to keep `start > end > shallow > bottom` (and
that curl could adopt next time anyone touches its per-tier loop).

Three cases are pinned per plan §6.1.8:
  1. no violations → values unchanged, empty violations list
  2. one violation → single value clamped, single violation reported
  3. cascading violations across three adjacent pairs → multiple clamps
"""

from __future__ import annotations

from scripts.invariants import enforce_ordering


def test_no_violations_returns_input_unchanged():
    # Strictly descending in `order` — no clamping needed.
    thresholds = {"start": 165.0, "end": 160.0, "shallow": 130.0, "bottom": 90.0}
    clamped, violations = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=1.0,
    )
    assert clamped == thresholds
    # `clamped` is a copy — mutating the result must not affect the input.
    assert clamped is not thresholds
    assert violations == []


def test_single_violation_clamps_one_value():
    # `end` is above `shallow` — but the iteration walks (start,end),
    # (end,shallow), (shallow,bottom). The (end,shallow) pair is the
    # offender: shallow gets pulled down to end - min_gap.
    thresholds = {"start": 165.0, "end": 160.0, "shallow": 162.0, "bottom": 90.0}
    clamped, violations = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=1.0,
    )
    assert len(violations) == 1
    assert "end" in violations[0] and "shallow" in violations[0]
    assert clamped["start"] == 165.0
    assert clamped["end"] == 160.0
    assert clamped["shallow"] == 159.0   # end - 1.0
    assert clamped["bottom"] == 90.0


def test_cascading_violations_walk_forward():
    # `start` is genuinely the largest, but every value below it is wrong:
    # end > start, shallow > end, bottom > shallow. After one pass each
    # subsequent value is dragged down by `min_gap` from its upper.
    thresholds = {"start": 100.0, "end": 200.0, "shallow": 300.0, "bottom": 400.0}
    clamped, violations = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=1.0,
    )
    # All three adjacent pairs violate → three formatted messages.
    assert len(violations) == 3
    # The cascade — each lower is the upper minus min_gap, since the
    # upper has already been clamped at this point in the walk.
    assert clamped["start"] == 100.0
    assert clamped["end"] == 99.0
    assert clamped["shallow"] == 98.0
    assert clamped["bottom"] == 97.0


def test_equal_values_count_as_violations():
    # `start == end` is not strictly descending. The helper uses `<=`
    # (`if clamped[upper] <= clamped[lower]:`) so equality fires too.
    thresholds = {"start": 100.0, "end": 100.0, "shallow": 50.0, "bottom": 25.0}
    clamped, violations = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=1.0,
    )
    assert len(violations) == 1
    assert clamped["end"] == 99.0


def test_min_gap_is_configurable():
    # A 5° gap separates the upper from the clamped lower.
    thresholds = {"start": 100.0, "end": 105.0, "shallow": 50.0, "bottom": 25.0}
    clamped, _ = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=5.0,
    )
    assert clamped["end"] == 95.0   # start - 5.0


def test_input_dict_is_not_mutated():
    # Defensive contract: the helper returns a new dict so callers can
    # diff input-vs-output without copying first.
    thresholds = {"start": 100.0, "end": 200.0, "shallow": 50.0, "bottom": 25.0}
    snapshot = dict(thresholds)
    _, _ = enforce_ordering(
        thresholds,
        order=["start", "end", "shallow", "bottom"],
        min_gap=1.0,
    )
    assert thresholds == snapshot
