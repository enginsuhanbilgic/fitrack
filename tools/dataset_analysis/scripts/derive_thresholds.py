"""Phase D — Percentile-based threshold derivation.

Consumes data/derived/per_rep_stats.csv (from compute_rep_stats.py) and emits
a thresholds payload that the Dart generator turns into a committed .dart file.

Derivation rules (biceps curl):
    start_angle  = percentile(good_reps.start_angle, 20) - 5° safety margin
    peak_angle   = percentile(good_reps.peak_angle,  75) + 5° safety margin
    peak_exit    = peak_angle + kCurlPeakExitGap (15°, kept as invariant)
    end_angle    = percentile(good_reps.end_angle,   20) - 5° safety margin

Every derived value has a 95% bootstrap CI attached so reviewers can see how
tightly each number is constrained by the data.

Invariants enforced BEFORE writing anything:
    * start_angle > peak_angle + peak_exit_gap   (FSM must be enterable)
    * start_angle > end_angle                    (rep must close below start)
    * end_angle   > peak_angle + peak_exit_gap   (ECCENTRIC must reach end)

Violations cause a non-zero exit — CI gates on this.

Usage:
    python scripts/derive_thresholds.py
    python scripts/derive_thresholds.py --stats data/derived/per_rep_stats.csv \\
                                        --out data/derived/thresholds.json
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
DERIVED_DIR = REPO_ROOT / "data" / "derived"

DEFAULT_STATS = DERIVED_DIR / "per_rep_stats.csv"
DEFAULT_OUTPUT = DERIVED_DIR / "thresholds.json"

# Safety margins (degrees). The percentile is the "typical" value; the margin
# widens the gate slightly so borderline-good reps aren't rejected.
SAFETY_MARGIN_DEG = 5.0

# FSM invariant — mirrors kCurlPeakExitGap in app/lib/core/constants.dart. We
# import it here so the Python side stays authoritative about the gap.
CURL_PEAK_EXIT_GAP_DEG = 15.0

# Bootstrap configuration — 1000 resamples is the usual sweet spot for 95% CIs
# at N ≤ 200. If the dataset grows beyond that we can bump it without changing
# any of the downstream math.
BOOTSTRAP_RESAMPLES = 1000
BOOTSTRAP_SEED = 1234  # deterministic CIs so two runs on the same data agree


# ---------------------------------------------------------------------------
# Input row — a leaner mirror of RepStats for just the fields we consume.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class StatsRow:
    clip_id: str
    rep_idx: int
    quality: str
    start_angle: Optional[float]
    peak_angle: Optional[float]
    end_angle: Optional[float]

    @staticmethod
    def from_csv_dict(row: dict[str, str]) -> "StatsRow":
        return StatsRow(
            clip_id=row["clip_id"],
            rep_idx=int(row["rep_idx"]),
            quality=row["quality"].strip().lower(),
            start_angle=_maybe_float(row.get("start_angle")),
            peak_angle=_maybe_float(row.get("peak_angle")),
            end_angle=_maybe_float(row.get("end_angle")),
        )


def _maybe_float(raw: Optional[str]) -> Optional[float]:
    if raw is None or raw.strip() == "":
        return None
    return float(raw)


def read_stats_csv(path: Path) -> list[StatsRow]:
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        return [StatsRow.from_csv_dict(r) for r in reader]


# ---------------------------------------------------------------------------
# Percentile / bootstrap math — intentionally in pure Python so we can run
# these tests in any environment without numpy installed.
# ---------------------------------------------------------------------------


def percentile(values: list[float], q: float) -> float:
    """Linear-interpolation percentile matching numpy's default (method="linear").

    `q` is in [0, 100]. Empty input raises ValueError because the caller
    should have filtered quality beforehand.
    """
    if not values:
        raise ValueError("percentile of empty sequence")
    if q < 0 or q > 100:
        raise ValueError(f"percentile q must be in [0, 100], got {q}")
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    # NumPy "linear" formula: index = q/100 * (N - 1)
    idx = (q / 100.0) * (len(s) - 1)
    lo = math.floor(idx)
    hi = math.ceil(idx)
    if lo == hi:
        return s[int(idx)]
    frac = idx - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def bootstrap_ci(
    values: list[float],
    q: float,
    resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float]:
    """Return the 95% bootstrap CI of the `q`-th percentile of `values`.

    Implementation: resample with replacement, compute the percentile on each
    resample, then report the 2.5/97.5% bounds of the resulting distribution.
    A fixed seed keeps two runs reproducible.
    """
    if not values:
        raise ValueError("bootstrap_ci on empty sequence")
    if len(values) == 1:
        return values[0], values[0]
    rng = random.Random(seed)
    n = len(values)
    samples: list[float] = []
    for _ in range(resamples):
        resample = [values[rng.randrange(n)] for _ in range(n)]
        samples.append(percentile(resample, q))
    lo = percentile(samples, 2.5)
    hi = percentile(samples, 97.5)
    return lo, hi


# ---------------------------------------------------------------------------
# Threshold record — what we write to JSON / hand to generate_dart.py
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ThresholdEstimate:
    """One threshold with its point estimate and 95% CI bounds."""

    value_deg: float
    ci_low_deg: float
    ci_high_deg: float
    n: int
    source_percentile: float
    safety_margin_deg: float

    def to_dict(self) -> dict:
        return {
            "value_deg": round(self.value_deg, 3),
            "ci_low_deg": round(self.ci_low_deg, 3),
            "ci_high_deg": round(self.ci_high_deg, 3),
            "n": self.n,
            "source_percentile": self.source_percentile,
            "safety_margin_deg": self.safety_margin_deg,
        }


@dataclass(frozen=True)
class CurlThresholds:
    start_angle: ThresholdEstimate
    peak_angle: ThresholdEstimate
    peak_exit_angle: ThresholdEstimate
    end_angle: ThresholdEstimate
    peak_exit_gap_deg: float  # authoritative; mirrors kCurlPeakExitGap
    dataset_summary: dict

    def to_dict(self) -> dict:
        return {
            "curl": {
                "start_angle": self.start_angle.to_dict(),
                "peak_angle": self.peak_angle.to_dict(),
                "peak_exit_angle": self.peak_exit_angle.to_dict(),
                "end_angle": self.end_angle.to_dict(),
                "peak_exit_gap_deg": self.peak_exit_gap_deg,
            },
            "dataset_summary": self.dataset_summary,
        }


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------


def filter_good(rows: Iterable[StatsRow]) -> list[StatsRow]:
    """Only reps labelled `good` feed the percentile math."""
    return [r for r in rows if r.quality == "good"]


def _column(rows: Iterable[StatsRow], field: str) -> list[float]:
    return [v for v in (getattr(r, field) for r in rows) if v is not None]


def derive_curl_thresholds(rows: list[StatsRow]) -> CurlThresholds:
    """Map good-rep stats → derived thresholds with CIs. Raises if too thin."""
    good = filter_good(rows)
    if len(good) < 5:
        raise ValueError(
            f"Need at least 5 good reps to derive thresholds, got {len(good)}"
        )

    starts = _column(good, "start_angle")
    peaks = _column(good, "peak_angle")
    ends = _column(good, "end_angle")

    if not starts or not peaks or not ends:
        raise ValueError(
            "At least one of start_angle / peak_angle / end_angle has no "
            "non-null samples across good reps — cannot derive thresholds."
        )

    # Start angle: rejected when elbow is still too straight. Use p20 so 80%
    # of good reps easily cross the gate, minus a 5° margin for tolerance.
    start_p20 = percentile(starts, 20)
    start_ci = bootstrap_ci(starts, 20)
    start = ThresholdEstimate(
        value_deg=start_p20 - SAFETY_MARGIN_DEG,
        ci_low_deg=start_ci[0] - SAFETY_MARGIN_DEG,
        ci_high_deg=start_ci[1] - SAFETY_MARGIN_DEG,
        n=len(starts),
        source_percentile=20.0,
        safety_margin_deg=SAFETY_MARGIN_DEG,
    )

    # Peak angle: the shallowest peak we still call "good". p75 + 5° margin
    # means the threshold sits above most good peaks so partial reps fail.
    peak_p75 = percentile(peaks, 75)
    peak_ci = bootstrap_ci(peaks, 75)
    peak = ThresholdEstimate(
        value_deg=peak_p75 + SAFETY_MARGIN_DEG,
        ci_low_deg=peak_ci[0] + SAFETY_MARGIN_DEG,
        ci_high_deg=peak_ci[1] + SAFETY_MARGIN_DEG,
        n=len(peaks),
        source_percentile=75.0,
        safety_margin_deg=SAFETY_MARGIN_DEG,
    )

    # Peak exit is derived (peak + kCurlPeakExitGap), NOT percentile-fitted.
    peak_exit = ThresholdEstimate(
        value_deg=peak.value_deg + CURL_PEAK_EXIT_GAP_DEG,
        ci_low_deg=peak.ci_low_deg + CURL_PEAK_EXIT_GAP_DEG,
        ci_high_deg=peak.ci_high_deg + CURL_PEAK_EXIT_GAP_DEG,
        n=peak.n,
        source_percentile=peak.source_percentile,
        safety_margin_deg=peak.safety_margin_deg,
    )

    # End angle: mirrors the start gate. p20 - 5° margin.
    end_p20 = percentile(ends, 20)
    end_ci = bootstrap_ci(ends, 20)
    end = ThresholdEstimate(
        value_deg=end_p20 - SAFETY_MARGIN_DEG,
        ci_low_deg=end_ci[0] - SAFETY_MARGIN_DEG,
        ci_high_deg=end_ci[1] - SAFETY_MARGIN_DEG,
        n=len(ends),
        source_percentile=20.0,
        safety_margin_deg=SAFETY_MARGIN_DEG,
    )

    summary = {
        "total_rows": len(rows),
        "good_rows": len(good),
        "clips": len({r.clip_id for r in rows}),
    }

    thresholds = CurlThresholds(
        start_angle=start,
        peak_angle=peak,
        peak_exit_angle=peak_exit,
        end_angle=end,
        peak_exit_gap_deg=CURL_PEAK_EXIT_GAP_DEG,
        dataset_summary=summary,
    )
    check_invariants(thresholds)
    return thresholds


# ---------------------------------------------------------------------------
# Invariant checks — the FSM must remain completable end-to-end.
# ---------------------------------------------------------------------------


class InvariantError(ValueError):
    """Raised when derived thresholds would produce an un-enterable FSM."""


def check_invariants(t: CurlThresholds) -> None:
    start = t.start_angle.value_deg
    peak = t.peak_angle.value_deg
    peak_exit = t.peak_exit_angle.value_deg
    end = t.end_angle.value_deg

    if not (start > peak_exit):
        raise InvariantError(
            f"FSM invariant violated: start_angle ({start:.2f}) must be > "
            f"peak_exit ({peak_exit:.2f}) so CONCENTRIC can be re-entered."
        )
    if not (start > end):
        raise InvariantError(
            f"FSM invariant violated: start_angle ({start:.2f}) must be > "
            f"end_angle ({end:.2f}) — a rep can never close otherwise."
        )
    if not (end > peak_exit):
        raise InvariantError(
            f"FSM invariant violated: end_angle ({end:.2f}) must be > "
            f"peak_exit ({peak_exit:.2f}) — ECCENTRIC could not reach end."
        )
    if peak >= start:
        raise InvariantError(
            f"FSM invariant violated: peak_angle ({peak:.2f}) must be < "
            f"start_angle ({start:.2f}) — a valid flex is below the entry gate."
        )


# ---------------------------------------------------------------------------
# IO
# ---------------------------------------------------------------------------


def write_thresholds_json(thresholds: CurlThresholds, out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        json.dump(thresholds.to_dict(), f, indent=2, sort_keys=True)
        f.write("\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Derive data-driven FSM thresholds from per-rep stats using "
            "percentile + bootstrap CI, enforce FSM invariants, and emit a "
            "reviewable JSON payload."
        )
    )
    parser.add_argument("--stats", type=Path, default=DEFAULT_STATS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUTPUT)
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)

    if not args.stats.exists():
        print(f"error: stats CSV not found at {args.stats}", file=sys.stderr)
        return 2

    rows = read_stats_csv(args.stats)
    if not rows:
        print(
            "error: stats CSV is empty — run compute_rep_stats.py first.",
            file=sys.stderr,
        )
        return 2

    try:
        thresholds = derive_curl_thresholds(rows)
    except (ValueError, InvariantError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    write_thresholds_json(thresholds, args.out)
    print(
        f"Wrote thresholds -> {args.out} "
        f"(good={thresholds.dataset_summary['good_rows']}, "
        f"clips={thresholds.dataset_summary['clips']})",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "BOOTSTRAP_RESAMPLES",
    "BOOTSTRAP_SEED",
    "CURL_PEAK_EXIT_GAP_DEG",
    "CurlThresholds",
    "InvariantError",
    "SAFETY_MARGIN_DEG",
    "StatsRow",
    "ThresholdEstimate",
    "bootstrap_ci",
    "build_parser",
    "check_invariants",
    "derive_curl_thresholds",
    "filter_good",
    "main",
    "percentile",
    "read_stats_csv",
    "write_thresholds_json",
]
