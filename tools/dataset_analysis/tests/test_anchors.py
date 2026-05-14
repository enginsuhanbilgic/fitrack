"""Tests for `scripts.anchors` — the named anchor functions that encode
the ROM-vs-fault-bound choice in `.agent_brain/SKILLS.md` "Threshold
Derivation Pipeline" doctrine.

`median_anchor` and `p95_anchor` are thin wrappers around shared stats
primitives. The point of these tests is doctrine enforcement — anyone
reaching for an anchor sees these tests and reads what each name means.
"""

from __future__ import annotations

from scripts.anchors import median_anchor, p95_anchor
from scripts.stats import bca_ci, hd_percentile


def test_median_anchor_matches_bootstrapped_p50():
    # `median_anchor` is literally `bca_ci(values, P50)[2]` — the point
    # estimate, not the CI bounds. Same RNG seed both times.
    vs = [10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0, 28.0]
    direct = bca_ci(vs, lambda xs: hd_percentile(xs, 50.0))[2]
    via_anchor = median_anchor(vs)
    assert abs(direct - via_anchor) < 1e-9


def test_median_anchor_handles_singleton():
    # Through the bca_ci fallback path: n<2 ⇒ value returned unmodified.
    assert median_anchor([42.0]) == 42.0


def test_median_anchor_is_robust_to_one_outlier():
    # The point of using median (not mean) — pulling one rep wildly low
    # should NOT swing the anchor by half the outlier's distance.
    base = [88.0, 88.5, 89.0, 87.5, 88.2, 88.1, 88.3, 88.4, 88.0]
    base_median = median_anchor(base)
    with_outlier = base + [40.0]
    out_median = median_anchor(with_outlier)
    # The shift should be < 1°, not the ~5° a mean would absorb.
    assert abs(out_median - base_median) < 1.0


def test_p95_anchor_matches_hd_p95():
    # `p95_anchor` is `hd_percentile(values, 95.0)` directly — no
    # bootstrap. The doctrine-named alias is the point: anyone reading
    # the squat form-audit derivation should land on `p95_anchor`, not
    # an inline magic-number 95.0.
    vs = list(range(101))   # 0..100
    assert p95_anchor(vs) == hd_percentile(vs, 95.0)


def test_p95_anchor_lands_near_upper_tail():
    # P95 on a uniform 0..100 sample lands near 95 (with HD smoothing
    # at small n).
    vs = list(range(101))
    p95 = p95_anchor(vs)
    assert 93.0 < p95 < 97.0


def test_p95_anchor_uses_PERCENT_not_fraction():
    # Regression guard: the squat form-audit code pre-PR-B was calling
    # `hd_percentile(vs, 0.95)` (FRACTION, not percent), which under
    # `hd_percentile`'s percent contract returned the 0.95th percentile —
    # i.e. near the minimum. Anyone replacing `p95_anchor` with the
    # underlying primitive must remember to pass 95.0, not 0.95.
    vs = list(range(101))
    p95 = p95_anchor(vs)
    # If `p95_anchor` were accidentally calling P0.95, we'd get a value
    # near 0, not 95. The doctrine: assert we are in the upper half.
    assert p95 > 50.0
