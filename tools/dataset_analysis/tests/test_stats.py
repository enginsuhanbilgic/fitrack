"""Sanity tests for the moved statistics helpers (2026-05-14 PR B).

`scripts.stats` is a verbatim move of `hd_percentile`, `bca_ci`,
`mad_reject`, and `design_effect` out of
`derive_thresholds_from_telemetry.py`. These tests lock the moved
behavior: they assert known answers on small fixtures so any future
refactor that subtly changes the numerics is caught immediately.

We do NOT re-test the underlying Beta CDF / probit numerics in depth — the
pre-extraction code shipped those for two years and the move is by-copy.
The point of this file is "the module still behaves the way the curl
derivation did", not "Harrell-Davis is correct."
"""

from __future__ import annotations

from scripts.stats import (
    BOOTSTRAP_RESAMPLES,
    BOOTSTRAP_SEED,
    MAD_REJECTION_THRESHOLD,
    bca_ci,
    design_effect,
    hd_percentile,
    mad_reject,
)


# ---------------------------------------------------------------------------
# hd_percentile
# ---------------------------------------------------------------------------

def test_hd_percentile_median_of_uniform_sample_is_centered():
    # On an odd-length uniform sample, the HD P50 sits within a fraction of
    # a unit of the sample median. The HD estimator differs from the order
    # statistic for small n by weighting neighbors — the expected delta is
    # under 1.0 for n=11.
    vs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    p50 = hd_percentile(vs, 50.0)
    assert 5.5 < p50 < 6.5


def test_hd_percentile_p95_is_near_upper_tail():
    # P95 on a uniform 0..100 sample should sit close to 95, give or take
    # the HD smoothing at small n.
    vs = list(range(101))   # 0..100 inclusive
    p95 = hd_percentile(vs, 95.0)
    assert 93.0 < p95 < 97.0


def test_hd_percentile_handles_singleton():
    # Pre-extraction the curl script guarded n==1; the move preserves it.
    assert hd_percentile([42.0], 50.0) == 42.0
    assert hd_percentile([42.0], 95.0) == 42.0


# ---------------------------------------------------------------------------
# bca_ci
# ---------------------------------------------------------------------------

def test_bca_ci_returns_point_estimate_for_median():
    # The point estimate from bca_ci equals the un-bootstrapped statistic
    # applied to the input. (The CI bounds depend on the bootstrap samples
    # and so are RNG-dependent; the point estimate is not.)
    vs = [10.0, 12.0, 14.0, 16.0, 18.0, 20.0, 22.0, 24.0, 26.0, 28.0]
    lo, hi, point = bca_ci(vs, lambda xs: hd_percentile(xs, 50.0))
    assert abs(point - hd_percentile(vs, 50.0)) < 1e-9
    assert lo <= point <= hi


def test_bca_ci_is_deterministic_with_default_seed():
    # The seeded RNG (`BOOTSTRAP_SEED=42`) means the same input + statistic
    # yields the same CI bounds across runs — load-bearing for the golden
    # output discipline of the derivation scripts.
    vs = [10.0, 12.0, 14.0, 16.0, 18.0, 20.0]
    first = bca_ci(vs, lambda xs: hd_percentile(xs, 50.0))
    second = bca_ci(vs, lambda xs: hd_percentile(xs, 50.0))
    assert first == second


def test_bca_ci_handles_singleton_and_empty():
    # Pre-extraction guards: n<2 returns the (only-or-fallback) value
    # triplicated. The post-extraction body preserves both branches.
    assert bca_ci([7.0], lambda xs: hd_percentile(xs, 50.0)) == (7.0, 7.0, 7.0)
    assert bca_ci([], lambda xs: hd_percentile(xs, 50.0)) == (0.0, 0.0, 0.0)


# ---------------------------------------------------------------------------
# mad_reject
# ---------------------------------------------------------------------------

def test_mad_reject_removes_obvious_outlier():
    # A single value far from the cluster is removed under the default
    # 3.5x MAD threshold.
    cluster = [88.0, 88.2, 88.4, 88.1, 88.3, 88.0, 88.2, 88.1, 88.3, 88.2]
    kept = mad_reject(cluster + [40.0])
    assert 40.0 not in kept
    assert len(kept) == len(cluster)


def test_mad_reject_returns_copy_when_n_lt_4():
    # Too-thin sample: MAD is unreliable, so the helper returns a copy
    # of the input untouched.
    short = [88.0, 88.5, 89.0]
    kept = mad_reject(short)
    assert kept == short
    assert kept is not short   # copy, not the same list


def test_mad_reject_returns_copy_when_mad_is_zero():
    # All values identical → MAD=0; division would NaN, so the helper
    # returns the input untouched.
    identical = [88.0] * 10
    kept = mad_reject(identical)
    assert kept == identical


# ---------------------------------------------------------------------------
# design_effect
# ---------------------------------------------------------------------------

def test_design_effect_returns_unit_for_single_cluster():
    # One cluster ⇒ no clustering effect ⇒ deff=1.0, icc=0.0.
    deff, icc, eff_n = design_effect({0: [1.0, 2.0, 3.0, 4.0]})
    assert deff == 1.0
    assert icc == 0.0
    assert eff_n == 4


def test_design_effect_returns_unit_for_too_few_total_reps():
    # n_total<4 across all clusters → no correction.
    deff, icc, eff_n = design_effect({0: [1.0], 1: [2.0]})
    assert deff == 1.0
    assert icc == 0.0
    assert eff_n == 2


def test_design_effect_inflates_when_within_cluster_variance_is_small():
    # Two clusters with means far apart and within-cluster spread small:
    # ICC is high (most variance is between clusters), so deff > 1.0 and
    # effective_n < raw n_total.
    by_session = {
        0: [10.0, 10.1, 9.9, 10.0],
        1: [50.0, 50.1, 49.9, 50.0],
    }
    deff, icc, eff_n = design_effect(by_session)
    assert deff > 1.0
    assert icc > 0.5
    assert eff_n < 8


# ---------------------------------------------------------------------------
# Module constants
# ---------------------------------------------------------------------------

def test_constants_have_expected_values():
    # If anyone tunes these, every downstream derivation moves — pin the
    # values so the change shows up as a code review.
    assert MAD_REJECTION_THRESHOLD == 3.5
    assert BOOTSTRAP_RESAMPLES == 1_000
    assert BOOTSTRAP_SEED == 42
