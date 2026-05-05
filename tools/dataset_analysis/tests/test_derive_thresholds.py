"""Unit tests for scripts/derive_thresholds.py.

Covers:
    * percentile() — matches numpy semantics at the edge cases
    * bootstrap_ci() — determinism + sensible bounds
    * StatsRow CSV round-trip
    * derive_curl_thresholds() on synthetic good/bad mixtures
    * check_invariants() — positive and negative cases
"""

from __future__ import annotations

import csv
import json
from pathlib import Path

import pytest

from scripts.derive_thresholds import (
    BOOTSTRAP_SEED,
    CURL_PEAK_EXIT_GAP_DEG,
    SAFETY_MARGIN_DEG,
    CurlThresholds,
    InvariantError,
    StatsRow,
    ThresholdEstimate,
    bootstrap_ci,
    build_parser,
    check_invariants,
    derive_curl_thresholds,
    filter_good,
    percentile,
    read_stats_csv,
    write_thresholds_json,
)


# ---------------------------------------------------------------------------
# percentile
# ---------------------------------------------------------------------------


def test_percentile_single_element_returns_that_element():
    assert percentile([42.0], 0.0) == 42.0
    assert percentile([42.0], 100.0) == 42.0
    assert percentile([42.0], 50.0) == 42.0


def test_percentile_endpoints_are_min_and_max():
    values = [1.0, 2.0, 3.0, 4.0, 5.0]
    assert percentile(values, 0) == 1.0
    assert percentile(values, 100) == 5.0


def test_percentile_50_of_uniform_is_middle():
    # numpy linear interp on [1..5] at q=50 -> 3.0
    assert percentile([1.0, 2.0, 3.0, 4.0, 5.0], 50) == pytest.approx(3.0)


def test_percentile_linear_interpolates_between_neighbours():
    # [10, 20, 30, 40] -> q=25 lands at idx 0.75 -> 10 + 0.75*(20-10) = 17.5
    assert percentile([10.0, 20.0, 30.0, 40.0], 25) == pytest.approx(17.5)


def test_percentile_rejects_out_of_range_q():
    with pytest.raises(ValueError):
        percentile([1.0, 2.0], -1)
    with pytest.raises(ValueError):
        percentile([1.0, 2.0], 101)


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        percentile([], 50)


# ---------------------------------------------------------------------------
# bootstrap_ci
# ---------------------------------------------------------------------------


def test_bootstrap_ci_deterministic_with_fixed_seed():
    """Same seed + same values -> bit-exact CI bounds across runs."""
    values = [float(v) for v in range(1, 21)]
    lo1, hi1 = bootstrap_ci(values, 50, resamples=200, seed=7)
    lo2, hi2 = bootstrap_ci(values, 50, resamples=200, seed=7)
    assert lo1 == lo2
    assert hi1 == hi2


def test_bootstrap_ci_contains_point_estimate_on_large_sample():
    values = [float(v) for v in range(1, 101)]  # 1..100
    point = percentile(values, 50)  # 50.5
    lo, hi = bootstrap_ci(values, 50, resamples=400, seed=11)
    assert lo <= point <= hi


def test_bootstrap_ci_single_element_collapses_to_point():
    lo, hi = bootstrap_ci([7.0], 50)
    assert lo == 7.0
    assert hi == 7.0


def test_bootstrap_ci_rejects_empty():
    with pytest.raises(ValueError):
        bootstrap_ci([], 50)


# ---------------------------------------------------------------------------
# StatsRow / read_stats_csv
# ---------------------------------------------------------------------------


def test_stats_row_from_csv_dict_parses_and_lowercases():
    row = StatsRow.from_csv_dict(
        {
            "clip_id": "clip_001",
            "rep_idx": "3",
            "quality": "GOOD",
            "start_angle": "165.5",
            "peak_angle": "62.0",
            "end_angle": "",
        }
    )
    assert row.clip_id == "clip_001"
    assert row.rep_idx == 3
    assert row.quality == "good"
    assert row.start_angle == pytest.approx(165.5)
    assert row.peak_angle == pytest.approx(62.0)
    assert row.end_angle is None


def test_read_stats_csv_round_trip(tmp_path: Path):
    path = tmp_path / "stats.csv"
    path.write_text(
        "clip_id,rep_idx,quality,start_angle,peak_angle,end_angle\n"
        "c1,1,good,165,62,150\n"
        "c1,2,bad_swing,158,68,145\n",
        encoding="utf-8",
    )
    rows = read_stats_csv(path)
    assert len(rows) == 2
    assert rows[0].quality == "good"
    assert rows[1].quality == "bad_swing"


# ---------------------------------------------------------------------------
# filter_good
# ---------------------------------------------------------------------------


def _row(
    rep_idx: int,
    quality: str = "good",
    start: float | None = 165.0,
    peak: float | None = 60.0,
    end: float | None = 150.0,
) -> StatsRow:
    return StatsRow(
        clip_id="c1",
        rep_idx=rep_idx,
        quality=quality,
        start_angle=start,
        peak_angle=peak,
        end_angle=end,
    )


def test_filter_good_excludes_non_good_qualities():
    rows = [
        _row(1, "good"),
        _row(2, "bad_swing"),
        _row(3, "good"),
        _row(4, "bad_partial_rom"),
    ]
    good = filter_good(rows)
    assert [r.rep_idx for r in good] == [1, 3]


# ---------------------------------------------------------------------------
# derive_curl_thresholds — end-to-end on synthetic data.
# ---------------------------------------------------------------------------


def _build_good_dataset(n: int = 20) -> list[StatsRow]:
    """N good reps drawn from a realistic-ish spread."""
    # Starts cluster around 160-170, peaks around 55-70, ends around 145-158.
    rows: list[StatsRow] = []
    for i in range(n):
        rows.append(
            _row(
                rep_idx=i + 1,
                quality="good",
                start=160.0 + (i % 10),     # 160..169
                peak=55.0 + (i % 15),       # 55..69
                end=145.0 + (i % 13),       # 145..157
            )
        )
    return rows


def test_derive_curl_thresholds_produces_valid_estimates():
    rows = _build_good_dataset(20)
    t = derive_curl_thresholds(rows)
    # Each threshold has n = 20, source percentile correctly set
    assert t.start_angle.n == 20
    assert t.start_angle.source_percentile == 20.0
    assert t.peak_angle.source_percentile == 75.0
    assert t.end_angle.source_percentile == 20.0
    assert t.peak_exit_gap_deg == CURL_PEAK_EXIT_GAP_DEG
    # Safety margins are applied consistently
    assert t.start_angle.safety_margin_deg == SAFETY_MARGIN_DEG
    # peak_exit value is peak + gap
    assert t.peak_exit_angle.value_deg == pytest.approx(
        t.peak_angle.value_deg + CURL_PEAK_EXIT_GAP_DEG
    )


def test_derive_curl_thresholds_rejects_tiny_dataset():
    rows = [_row(i, "good") for i in range(3)]
    with pytest.raises(ValueError, match="at least 5 good reps"):
        derive_curl_thresholds(rows)


def test_derive_curl_thresholds_rejects_when_a_column_is_all_null():
    rows = [_row(i, "good", end=None) for i in range(1, 11)]
    with pytest.raises(ValueError, match="no non-null samples"):
        derive_curl_thresholds(rows)


def test_derive_curl_thresholds_ignores_bad_reps():
    good = _build_good_dataset(10)
    bad = [
        _row(100 + i, "bad_partial_rom", start=120.0, peak=110.0, end=115.0)
        for i in range(10)
    ]
    mixed = good + bad
    t_mixed = derive_curl_thresholds(mixed)
    t_clean = derive_curl_thresholds(good)
    # Bad reps shouldn't shift the derived values — only good reps feed the math.
    assert t_mixed.start_angle.value_deg == pytest.approx(t_clean.start_angle.value_deg)
    assert t_mixed.peak_angle.value_deg == pytest.approx(t_clean.peak_angle.value_deg)
    # But the dataset_summary counts them.
    assert t_mixed.dataset_summary["total_rows"] == 20
    assert t_mixed.dataset_summary["good_rows"] == 10


def test_derive_curl_thresholds_dataset_summary_counts_clips():
    rows = []
    for i in range(10):
        rows.append(
            StatsRow(
                clip_id=f"c{i % 3}",
                rep_idx=i,
                quality="good",
                start_angle=165.0,
                peak_angle=60.0,
                end_angle=150.0,
            )
        )
    t = derive_curl_thresholds(rows)
    assert t.dataset_summary["clips"] == 3


# ---------------------------------------------------------------------------
# check_invariants — the safety net that stops us from emitting a broken FSM.
# ---------------------------------------------------------------------------


def _estimate(value: float) -> ThresholdEstimate:
    return ThresholdEstimate(
        value_deg=value,
        ci_low_deg=value - 1,
        ci_high_deg=value + 1,
        n=10,
        source_percentile=50.0,
        safety_margin_deg=0.0,
    )


def _thresholds(start: float, peak: float, peak_exit: float, end: float) -> CurlThresholds:
    return CurlThresholds(
        start_angle=_estimate(start),
        peak_angle=_estimate(peak),
        peak_exit_angle=_estimate(peak_exit),
        end_angle=_estimate(end),
        peak_exit_gap_deg=CURL_PEAK_EXIT_GAP_DEG,
        dataset_summary={"total_rows": 0, "good_rows": 0, "clips": 0},
    )


def test_invariants_pass_for_realistic_values():
    # start 160, peak 70, peak_exit 85, end 140 — matches current shipped consts.
    check_invariants(_thresholds(start=160, peak=70, peak_exit=85, end=140))


def test_invariants_fail_when_start_below_peak_exit():
    with pytest.raises(InvariantError, match="start_angle"):
        check_invariants(_thresholds(start=80, peak=70, peak_exit=85, end=75))


def test_invariants_fail_when_start_below_end():
    with pytest.raises(InvariantError, match="start_angle"):
        check_invariants(_thresholds(start=100, peak=50, peak_exit=65, end=120))


def test_invariants_fail_when_end_below_peak_exit():
    with pytest.raises(InvariantError, match="end_angle"):
        check_invariants(_thresholds(start=200, peak=70, peak_exit=85, end=80))


def test_invariants_fail_when_peak_not_below_start():
    with pytest.raises(InvariantError, match="peak_angle"):
        check_invariants(_thresholds(start=80, peak=80, peak_exit=60, end=70))


# ---------------------------------------------------------------------------
# write_thresholds_json — shape / sort-key stability.
# ---------------------------------------------------------------------------


def test_write_thresholds_json_emits_stable_shape(tmp_path: Path):
    rows = _build_good_dataset(20)
    t = derive_curl_thresholds(rows)
    out = tmp_path / "thresholds.json"
    write_thresholds_json(t, out)

    payload = json.loads(out.read_text(encoding="utf-8"))
    assert "curl" in payload
    curl = payload["curl"]
    for key in ("start_angle", "peak_angle", "peak_exit_angle", "end_angle"):
        assert key in curl
        for sub in ("value_deg", "ci_low_deg", "ci_high_deg", "n", "source_percentile"):
            assert sub in curl[key], f"missing {key}.{sub}"
    assert curl["peak_exit_gap_deg"] == CURL_PEAK_EXIT_GAP_DEG
    assert "dataset_summary" in payload


# ---------------------------------------------------------------------------
# build_parser
# ---------------------------------------------------------------------------


def test_parser_defaults_point_at_data_derived_dir():
    parser = build_parser()
    ns = parser.parse_args([])
    assert ns.stats.name == "per_rep_stats.csv"
    assert ns.out.name == "thresholds.json"


def test_parser_accepts_overrides():
    parser = build_parser()
    ns = parser.parse_args(["--stats", "s.csv", "--out", "o.json"])
    assert ns.stats == Path("s.csv")
    assert ns.out == Path("o.json")
