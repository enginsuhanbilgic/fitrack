"""Derive squat ROM FSM thresholds from FiTrack debug-session telemetry.

Squat Pipeline Overhaul — Part 4 (telemetry derivation tooling).

INPUT
    A plain-text paste of TelemetryLog entries copied via the Diagnostics
    screen's "Copy all" button, OR a path to a session telemetry file
    under ``data/telemetry/sessions/``. The script reads ``squat.rep``
    lines emitted by ``WorkoutViewModel._handleSquatRepCommit``.

    Each ``squat.rep`` line carries:
      rep=<int> variant=<bodyweight|highBarBackSquat> long_femur=<bool>
      lean_deg=<f|null> knee_shift=<f|null> heel_lift=<f|null>
      quality=<f|null> min_knee=<f|null> max_knee=<f|null>

    This script consumes ``min_knee`` and ``max_knee`` exclusively —
    form-threshold derivation (lean / shift / lift) lives in the curl
    script's ``--exercise squat`` mode for now.

WHAT IT EMITS
    A paste-ready Dart ``static const SquatRomThresholdSet`` block per
    variant, mirroring [SquatRomDefaults.defaults] /
    [SquatRomDefaults.forVariantAndSensitivity]. Use this output to
    replace the hand-tuned defaults in
    ``app/lib/core/squat_rom_defaults.dart`` once a representative
    cohort has been observed.

METHODOLOGY
    * Per-variant Harrell-Davis percentiles
        - bottomAngle  = P10 of min_knee (deeper than 90% of observed reps)
        - startAngle   = P90 of max_knee (more extended than 90% of observed)
        - endAngle     = P50 of max_knee (the typical return-to-extension)
    * MAD outlier rejection (3.5 × MAD) per-dimension — a rep with a
      noise spike on min_knee can still contribute a clean max_knee.
    * BCa 95% bootstrap CI (1 000 resamples) on each percentile.
    * Design-effect (ICC) correction using session as cluster.
    * FSM invariant: ``startAngle > endAngle > bottomAngle``. The
      output block is flagged with ⚠ if violated.

AUTO-SAVE
    When invoked with a file path: the report is auto-tee'd to
    ``tools/dataset_analysis/data/telemetry/derived/<input_stem>_squat_thresholds.txt``
    (or ``--out-dir`` if overridden). Stdin invocations are NOT auto-saved
    — preserves the "quick experiment" workflow used during live tuning.

USAGE
    # Named session file → auto-saved.
    python -m scripts.derive_squat_thresholds_from_telemetry \\
        data/telemetry/sessions/2026-05-13_squat_session.txt

    # Stdin pipe → terminal only.
    pbpaste | python -m scripts.derive_squat_thresholds_from_telemetry

    # Variant filter (skip mixed-variant sessions).
    python -m scripts.derive_squat_thresholds_from_telemetry session.txt --variant highBarBackSquat

WHY A SEPARATE SCRIPT
    The curl ``derive_thresholds_from_telemetry.py`` already handles
    squat **form-threshold** derivation (lean / shift / lift). Squat
    **ROM thresholds** (startAngle / bottomAngle / endAngle) are a
    distinct output with a distinct invariant — keeping them in a
    sibling script avoids cross-pollinating the curl tool's CLI surface
    with a third orthogonal `--rom` mode. Shared statistics (HD
    percentile, BCa CI, MAD rejection) are imported from the curl
    script so a fix to either lands in one place.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# Reuse the curl script's statistics — single source of truth keeps any
# bug fixes (e.g. BCa numerics) in one place.
from scripts.derive_thresholds_from_telemetry import (
    BOOTSTRAP_RESAMPLES,
    MAD_REJECTION_THRESHOLD,
    bca_ci,
    design_effect,
    hd_percentile,
)

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

# Default location for tee-captured derived reports. Resolved relative to
# this file so the script can be invoked from any cwd.
_DEFAULT_OUT_DIR = (
    Path(__file__).resolve().parent.parent / "data" / "telemetry" / "derived"
)

# Minimum reps to derive a per-variant block. Lower than curl's MIN_REPS_REQUIRED
# (5) because squat reps are slower; collecting 5 reps in a single set is
# practically the only way to get any data.
MIN_REPS_REQUIRED = 5

# Percentile choices for each ROM gate. P10/P90/P50 mirror the master spec
# (deep-research synthesis 2026-04-25) where the bottom gate sits at the
# 10th-percentile-deepest observed angle (covers 90% of users to that depth).
P_BOTTOM = 10.0  # bottomAngle = P10 of min_knee
P_START = 90.0   # startAngle  = P90 of max_knee
P_END = 50.0     # endAngle    = P50 of max_knee

# Mirrors derive_thresholds_from_telemetry's tee implementation.
class _Tee:
    """Forwards writes to multiple streams — used for terminal+file output."""

    def __init__(self, *streams):
        self._streams = streams

    def write(self, data):
        for s in self._streams:
            s.write(data)

    def flush(self):
        for s in self._streams:
            s.flush()


# ---------------------------------------------------------------------------
# Telemetry parsing — extends the curl script's squat parser with min/max_knee
# ---------------------------------------------------------------------------

# Note: this regex is intentionally separate from the curl script's
# `_SQUAT_REP_RE`. The curl script captures lean/shift/lift/quality but NOT
# min_knee/max_knee, because at the time it was written the ROM derivation
# wasn't in scope. Keeping a Part-4-local regex avoids a backward-incompatible
# edit to the curl script.
_SQUAT_REP_RE = re.compile(
    r"squat\.rep\s+"
    r"rep=\d+\s+"
    r"variant=(?P<variant>\S+)\s+"
    r"long_femur=(?P<long_femur>\S+).*?"
    r"min_knee=(?P<min_knee>[0-9.]+|null)\s+"
    r"max_knee=(?P<max_knee>[0-9.]+|null)"
)


@dataclass
class SquatRepRecord:
    session_idx: int
    variant: str
    long_femur: bool
    min_knee: Optional[float]
    max_knee: Optional[float]


def parse_squat_rep_lines(text: str) -> list[SquatRepRecord]:
    """Parse all ``squat.rep`` lines in the text into typed records.

    Sessions are delimited by ``squat_debug.session_start`` markers. Reps
    found before the first marker are treated as session 0 (anonymous).
    """
    reps: list[SquatRepRecord] = []
    blocks = text.split("squat_debug.session_start")
    # blocks[0] is anything before the first marker (often empty).
    # We treat every block as a session, including blocks[0], so that
    # production logs without markers still yield reps.
    for session_idx, block in enumerate(blocks):
        for m in _SQUAT_REP_RE.finditer(block):
            mn = m.group("min_knee")
            mx = m.group("max_knee")
            reps.append(
                SquatRepRecord(
                    session_idx=session_idx,
                    variant=m.group("variant"),
                    long_femur=m.group("long_femur") == "true",
                    min_knee=float(mn) if mn != "null" else None,
                    max_knee=float(mx) if mx != "null" else None,
                )
            )
    return reps


# ---------------------------------------------------------------------------
# Statistics — wraps the curl script's reusables with squat-specific semantics
# ---------------------------------------------------------------------------

def _median(values: list[float]) -> float:
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def _mad(values: list[float]) -> float:
    med = _median(values)
    return 1.4826 * _median([abs(v - med) for v in values])


def _mad_reject(values: list[float]) -> list[float]:
    """Return values minus outliers (> MAD_REJECTION_THRESHOLD × MAD)."""
    if len(values) < 4:
        return values[:]
    med = _median(values)
    mad = _mad(values)
    if mad == 0:
        return values[:]
    return [
        v for v in values
        if abs(v - med) / mad <= MAD_REJECTION_THRESHOLD
    ]


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

@dataclass
class DerivedSquatRom:
    variant: str
    n_reps: int
    n_kept_min: int
    n_kept_max: int
    n_sessions: int
    icc_min: float
    icc_max: float

    start_angle: float
    bottom_angle: float
    end_angle: float

    start_ci: tuple[float, float]
    bottom_ci: tuple[float, float]
    end_ci: tuple[float, float]

    invariants_ok: bool
    violations: list[str]


def derive_squat_rom(
    reps: list[SquatRepRecord],
    variant: str,
) -> Optional[DerivedSquatRom]:
    """Derive a SquatRomThresholdSet from per-variant reps. Returns None
    when either dimension has fewer than MIN_REPS_REQUIRED kept samples.

    Each dimension (min_knee, max_knee) is filtered independently by MAD
    outlier rejection — a rep with a clean min and a noisy max contributes
    its min and is dropped from the max series, mirroring the squat
    auto-calibrator's per-dimension acceptance policy.
    """
    variant_reps = [r for r in reps if r.variant == variant]
    if not variant_reps:
        return None

    min_vals = [r.min_knee for r in variant_reps if r.min_knee is not None]
    max_vals = [r.max_knee for r in variant_reps if r.max_knee is not None]

    if len(min_vals) < MIN_REPS_REQUIRED or len(max_vals) < MIN_REPS_REQUIRED:
        return None

    kept_min = _mad_reject(min_vals)
    kept_max = _mad_reject(max_vals)

    if len(kept_min) < MIN_REPS_REQUIRED or len(kept_max) < MIN_REPS_REQUIRED:
        return None

    # Group by session for ICC — design-effect correction shrinks the
    # effective n when reps within a session are correlated (typical:
    # one user's depth doesn't change much within a single set).
    by_session_min: dict[int, list[float]] = {}
    by_session_max: dict[int, list[float]] = {}
    for r in variant_reps:
        if r.min_knee is not None:
            by_session_min.setdefault(r.session_idx, []).append(r.min_knee)
        if r.max_knee is not None:
            by_session_max.setdefault(r.session_idx, []).append(r.max_knee)
    _, icc_min, _ = design_effect(by_session_min)
    _, icc_max, _ = design_effect(by_session_max)

    # Point estimates + BCa CI on the percentiles.
    def stat_bottom(vs: list[float]) -> float:
        return hd_percentile(vs, P_BOTTOM)

    def stat_start(vs: list[float]) -> float:
        return hd_percentile(vs, P_START)

    def stat_end(vs: list[float]) -> float:
        return hd_percentile(vs, P_END)

    b_lo, b_hi, bottom = bca_ci(kept_min, stat_bottom, n_boot=BOOTSTRAP_RESAMPLES)
    s_lo, s_hi, start = bca_ci(kept_max, stat_start, n_boot=BOOTSTRAP_RESAMPLES)
    e_lo, e_hi, end = bca_ci(kept_max, stat_end, n_boot=BOOTSTRAP_RESAMPLES)

    violations: list[str] = []
    if not (start > end):
        violations.append(
            f"startAngle ({start:.1f}°) must be > endAngle ({end:.1f}°)"
        )
    if not (end > bottom):
        violations.append(
            f"endAngle ({end:.1f}°) must be > bottomAngle ({bottom:.1f}°)"
        )

    n_sessions = len({r.session_idx for r in variant_reps})

    return DerivedSquatRom(
        variant=variant,
        n_reps=len(variant_reps),
        n_kept_min=len(kept_min),
        n_kept_max=len(kept_max),
        n_sessions=n_sessions,
        icc_min=icc_min,
        icc_max=icc_max,
        start_angle=start,
        bottom_angle=bottom,
        end_angle=end,
        start_ci=(s_lo, s_hi),
        bottom_ci=(b_lo, b_hi),
        end_ci=(e_lo, e_hi),
        invariants_ok=len(violations) == 0,
        violations=violations,
    )


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def dart_snippet(d: DerivedSquatRom) -> str:
    """Emit a paste-ready Dart SquatRomThresholdSet block."""
    inv = "" if d.invariants_ok else "  // ⚠ INVARIANT VIOLATION"
    lines = [
        f"// Derived squat ROM thresholds — variant: {d.variant}",
        f"// reps: {d.n_reps} raw, kept_min={d.n_kept_min} kept_max={d.n_kept_max}, "
        f"{d.n_sessions} session(s)",
        f"// ICC_min={d.icc_min:.3f}  ICC_max={d.icc_max:.3f}",
        f"// 95% BCa CI — start: [{d.start_ci[0]:.1f}°, {d.start_ci[1]:.1f}°], "
        f"bottom: [{d.bottom_ci[0]:.1f}°, {d.bottom_ci[1]:.1f}°], "
        f"end: [{d.end_ci[0]:.1f}°, {d.end_ci[1]:.1f}°]",
        f"static const SquatRomThresholdSet {d.variant}Defaults = "
        f"SquatRomThresholdSet({inv}",
        f"  startAngle: {d.start_angle:.1f},",
        f"  bottomAngle: {d.bottom_angle:.1f},",
        f"  endAngle: {d.end_angle:.1f},",
        f");",
    ]
    return "\n".join(lines)


def print_report(d: DerivedSquatRom) -> None:
    mark = "✅" if d.invariants_ok else "❌"
    print(f"\n{'='*60}")
    print(f"  {mark}  variant={d.variant}")
    print(f"  reps: {d.n_reps} raw → kept_min={d.n_kept_min} kept_max={d.n_kept_max}")
    print(f"  sessions: {d.n_sessions}   ICC_min={d.icc_min:.3f}   ICC_max={d.icc_max:.3f}")
    print()
    print(f"  startAngle  (P{P_START:.0f} of max_knee) = "
          f"{d.start_angle:>6.1f}°  CI [{d.start_ci[0]:.1f}°, {d.start_ci[1]:.1f}°]")
    print(f"  endAngle    (P{P_END:.0f} of max_knee) = "
          f"{d.end_angle:>6.1f}°  CI [{d.end_ci[0]:.1f}°, {d.end_ci[1]:.1f}°]")
    print(f"  bottomAngle (P{P_BOTTOM:.0f} of min_knee) = "
          f"{d.bottom_angle:>6.1f}°  CI [{d.bottom_ci[0]:.1f}°, {d.bottom_ci[1]:.1f}°]")
    print()
    if d.violations:
        print("  ⚠  INVARIANT VIOLATIONS:")
        for v in d.violations:
            print(f"      • {v}")
        print()
    print("  ── Dart snippet ─────────────────────────────────────")
    print(dart_snippet(d))
    print("  ─────────────────────────────────────────────────────")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _run_analysis(text: str, args: argparse.Namespace) -> int:
    reps = parse_squat_rep_lines(text)
    if not reps:
        print("error: no squat.rep lines found.", file=sys.stderr)
        print("Hints:", file=sys.stderr)
        print("  1. Verify telemetry text contains 'squat.rep' lines", file=sys.stderr)
        print("  2. squat.rep is always-on; check the input isn't truncated", file=sys.stderr)
        return 1

    variants = [args.variant] if args.variant else ("bodyweight", "highBarBackSquat")
    any_emitted = False
    any_failed = False
    for variant in variants:
        result = derive_squat_rom(reps, variant)
        if result is None:
            n = sum(1 for r in reps if r.variant == variant)
            print(
                f"\n⚠  ({variant}): only {n} reps (need ≥{MIN_REPS_REQUIRED} "
                f"per dimension after MAD rejection).",
                file=sys.stderr,
            )
            continue
        any_emitted = True
        print_report(result)
        if not result.invariants_ok:
            any_failed = True

    if not any_emitted:
        return 1
    return 1 if any_failed else 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Derive squat ROM FSM thresholds from FiTrack telemetry.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "telemetry_file",
        nargs="?",
        help="Path to telemetry text file. Reads stdin if omitted.",
    )
    parser.add_argument(
        "--variant",
        choices=["bodyweight", "highBarBackSquat"],
        help="Restrict analysis to a single squat variant.",
    )
    parser.add_argument(
        "--out-dir",
        default=str(_DEFAULT_OUT_DIR),
        metavar="DIR",
        help=(
            "Directory to auto-save the derived report into when a file path "
            "is passed as input. Filename: <stem>_squat_thresholds.txt. "
            "Stdin invocations are NOT auto-saved. "
            f"Default: {_DEFAULT_OUT_DIR}"
        ),
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Disable auto-save even when a file path is passed (terminal only).",
    )
    args = parser.parse_args(argv)

    if args.telemetry_file:
        try:
            text = open(args.telemetry_file, encoding="utf-8").read()
        except OSError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()

    if not text.strip():
        print(
            "error: no input — paste telemetry text or provide a file path.",
            file=sys.stderr,
        )
        return 2

    # Stdin: terminal output only — preserves the "quick experiment" workflow.
    out_path: Optional[Path] = None
    if args.telemetry_file and not args.no_save:
        in_stem = Path(args.telemetry_file).stem
        out_path = Path(args.out_dir) / f"{in_stem}_squat_thresholds.txt"
        try:
            out_path.parent.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            print(
                f"warning: could not create output dir {out_path.parent}: {e}",
                file=sys.stderr,
            )
            out_path = None

    if out_path is not None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(_Tee(sys.stdout, buf)):
            exit_code = _run_analysis(text, args)
        try:
            out_path.write_text(buf.getvalue(), encoding="utf-8")
            print(f"\n→ saved derived report: {out_path}", file=sys.stderr)
        except OSError as e:
            print(f"warning: could not write {out_path}: {e}", file=sys.stderr)
        return exit_code

    return _run_analysis(text, args)


if __name__ == "__main__":
    raise SystemExit(main())
