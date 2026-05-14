"""Shared invariant clamp helper.

Every per-exercise derivation has its own FSM ordering constraint
(curl: start > end > peakExit > peak; push-up: start > end > bottom; squat
form audit has no ordering constraint — its three metrics are independent).
Pre-extraction, each script implemented its own ad-hoc clamp inline. This
module hosts the single shared implementation.

The helper takes a dict of threshold values and a strict-descending
`order` list and clamps each adjacent pair to satisfy the ordering with a
configurable `min_gap`. Violations are returned as formatted strings so
the caller can fold them into the script's own invariant report — callers
decide whether to surface them as warnings, fail the run, or both.
"""

from __future__ import annotations


def enforce_ordering(
    thresholds: dict[str, float],
    order: list[str],
    min_gap: float = 1.0,
) -> tuple[dict[str, float], list[str]]:
    """Clamp adjacent pairs in `order` (largest → smallest) to satisfy strict
    descending ordering with `min_gap` separation.

    Walks the `order` list pairwise (`(order[0], order[1])`, `(order[1],
    order[2])`, …). For each pair where `clamped[upper] <= clamped[lower]`
    the lower value is pulled down to `clamped[upper] - min_gap` and the
    violation is recorded. Violations propagate forward through the
    cascade — if a later clamp also invalidates the next pair, the next
    iteration sees the already-clamped value and clamps again, so a
    single ascending value at the top can cascade through every pair.

    Returns:
        (clamped, violations) — `clamped` is a new dict (input is not
        mutated); `violations` is a list of human-readable strings.
        Empty list means no clamping happened.
    """
    clamped = dict(thresholds)
    violations: list[str] = []
    for upper, lower in zip(order, order[1:]):
        if clamped[upper] <= clamped[lower]:
            violations.append(
                f"{upper} ({clamped[upper]:.1f}) must be > {lower} ({clamped[lower]:.1f})"
            )
            clamped[lower] = clamped[upper] - min_gap
    return clamped, violations
