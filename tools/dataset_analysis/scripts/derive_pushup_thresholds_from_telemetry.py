"""Derive push-up ROM FSM thresholds from FiTrack debug-session telemetry.

Push-Up Telemetry Threshold Tuning (2026-05-13) — Phase 2.

INPUT
    A plain-text paste of TelemetryLog entries copied via the Diagnostics
    screen's "Copy all" button, OR a path to a session telemetry file
    under ``data/telemetry/sessions/``. The script reads ``pushup.rep``
    lines emitted by ``WorkoutViewModel._handlePushUpRepCommit``.

    Each ``pushup.rep`` line carries:
      rep=<int> min_elbow=<f|null> max_elbow=<f|null>

    The v1 line is intentionally minimal — variant detection, body-line
    deviation, and per-rep quality are out of scope here. When those land
    they extend both the Dart `formatPushUpRepLine` helper and the regex
    below in lock-step.

WHAT IT EMITS
    A paste-ready Dart ``static const PushUpRomThresholdSet`` block per
    ``(P_BOTTOM, P_START)`` combination from the percentile sweep, mirroring
    the shape of [PushUpRomDefaults._high] / [PushUpRomDefaults._medium].
    Use the recommended (P_BOTTOM=10, P_START=90) block as the cold-start
    medium-sensitivity default; the tighter P_BOTTOM=15 / P_START=85 row
    feeds the `_high` tier, the looser P_BOTTOM=5 / P_START=95 row feeds a
    future `_low` tier.

METHODOLOGY
    * Harrell-Davis percentiles for each gate
        - bottomAngle  = P_BOTTOM of min_elbow (deeper than (100 - P) % of reps)
        - startAngle   = P_START  of max_elbow (more extended than (100 - P) %)
        - endAngle     = P50      of max_elbow (typical return-to-extension)
        - shallowMax   = P_SHALLOW of min_elbow (shallow gate sits above bottom)
    * MAD outlier rejection (3.5 × MAD) per-dimension — a rep with a noisy
      min_elbow can still contribute a clean max_elbow.
    * BCa 95 % bootstrap CI (1 000 resamples) on each percentile.
    * Design-effect (ICC) correction using session as cluster.
    * FSM invariant: ``startAngle > endAngle > bottomAngle``. The output
      block is flagged with ⚠ if violated.

AUTO-SAVE
    When invoked with a file path the report is auto-tee'd to
    ``tools/dataset_analysis/data/telemetry/derived/<input_stem>_pushup_thresholds.txt``
    (or ``--out-dir`` if overridden). Stdin invocations are NOT auto-saved
    — preserves the "quick experiment" workflow used during live tuning,
    matching the squat script's policy.

SESSION BOUNDARIES
    Sessions are delimited by ``curl_debug.session_start`` markers (the
    universal session boundary in TelemetryLog — push-up does NOT emit
    its own marker in v1). When markers are absent the parser treats the
    whole paste as one cluster; the ICC design-effect correction handles
    the degenerate case gracefully (deff → 1.0).

USAGE
    # Named session file → auto-saved.
    python -m scripts.derive_pushup_thresholds_from_telemetry \\
        data/telemetry/sessions/2026-05-13_pushup_session.txt

    # Stdin pipe → terminal only.
    pbpaste | python -m scripts.derive_pushup_thresholds_from_telemetry

WHY A SEPARATE SCRIPT
    Push-up ROM thresholds derive from a different signal (elbow angle)
    than squat (knee angle), and shipping a single multi-exercise CLI
    would force every push-up tuning run to disambiguate via flags. The
    statistics helpers (`hd_percentile`, `bca_ci`, `design_effect`) come
    from the curl script so a fix to the math lands in one place.
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
# bug fix (e.g. BCa numerics) in one place across all three exercises.
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

# Minimum reps required to derive a block. Matches the squat script —
# push-up sets are typically 8–12 reps so 5 is a realistic floor for one
# session, and pooling across sessions covers thinner data.
MIN_REPS_REQUIRED = 5

# Percentile sweep — emit one block per (P_BOTTOM, P_START) pair so the
# reader can pick the row that maps to the Dart sensitivity tier they want.
# Wider spread (P5/P95) = looser gates = lower sensitivity. Tighter spread
# (P15/P85) = stricter gates = higher sensitivity. The plan's tier table:
#   high   → P15 / P85   (strictest)
#   medium → P10 / P90   (recommended cold-start default)
#   low    → P5  / P95   (most permissive — future Dart tier)
P_BOTTOM_SWEEP = (5.0, 10.0, 15.0)
P_START_SWEEP = (85.0, 90.0, 95.0)

# Fixed picks — same across all tiers.
P_END_FIXED = 50.0
# Shallow gate sits above the bottom: must be deeper than P_BOTTOM (so a
# rep that reverses above this still counts as "made an attempt") but
# above a representative depth. P25 of min_elbow is the medium pick;
# the Dart layer's sensitivity tiering uses P30 / P25 / P20 for
# high / medium / low. The script reports P25 here; producing the full
# triple is a one-line extension when the Dart side actually consumes it.
P_SHALLOW = 25.0


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
# Telemetry parsing
# ---------------------------------------------------------------------------

# Anchored on the fixed-order line shape emitted by `formatPushUpRepLine`.
# No optional fields — `null` is the literal string, never an omitted token.
# If the Dart format grows (variant, body_line_dev, quality), the new
# fields land here as named groups in the same change.
_PUSHUP_REP_RE = re.compile(
    r"pushup\.rep\s+"
    r"rep=\d+\s+"
    r"min_elbow=(?P<min_elbow>[0-9.]+|null)\s+"
    r"max_elbow=(?P<max_elbow>[0-9.]+|null)"
)


@dataclass
class PushUpRepRecord:
    """One parsed `pushup.rep` line. ``session_idx`` indexes the
    `curl_debug.session_start` delimited block this rep was found in;
    pastes without markers yield all-zero indices and the ICC correction
    collapses to deff=1.0.
    """

    session_idx: int
    min_elbow: Optional[float]
    max_elbow: Optional[float]


def parse_pushup_rep_lines(text: str) -> list[PushUpRepRecord]:
    """Parse all ``pushup.rep`` lines in ``text`` into typed records.

    Sessions are delimited by ``curl_debug.session_start`` markers — the
    universal TelemetryLog session boundary. Reps before the first marker
    are treated as session 0 (anonymous); pastes with no marker yield a
    single cluster and the ICC step degenerates gracefully.
    """
    reps: list[PushUpRepRecord] = []
    blocks = text.split("curl_debug.session_start")
    for session_idx, block in enumerate(blocks):
        for m in _PUSHUP_REP_RE.finditer(block):
            mn = m.group("min_elbow")
            mx = m.group("max_elbow")
            reps.append(
                PushUpRepRecord(
                    session_idx=session_idx,
                    min_elbow=float(mn) if mn != "null" else None,
                    max_elbow=float(mx) if mx != "null" else None,
                )
            )
    return reps


# ---------------------------------------------------------------------------
# Statistics — wraps the curl script's reusables with push-up semantics
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
class DerivedPushUpRom:
    p_bottom: float
    p_start: float

    n_reps: int
    n_kept_min: int
    n_kept_max: int
    n_sessions: int
    icc_min: float
    icc_max: float

    start_angle: float
    bottom_angle: float
    end_angle: float
    shallow_rep_max_angle: float

    start_ci: tuple[float, float]
    bottom_ci: tuple[float, float]
    end_ci: tuple[float, float]
    shallow_ci: tuple[float, float]

    invariants_ok: bool
    violations: list[str]


def derive_pushup_thresholds(
    reps: list[PushUpRepRecord],
    p_bottom: float,
    p_start: float,
) -> Optional[DerivedPushUpRom]:
    """Derive a PushUpRomThresholdSet from ``reps`` at the given percentile
    pair. Returns None when either dimension has fewer than
    ``MIN_REPS_REQUIRED`` kept samples.

    Each dimension (min_elbow, max_elbow) is MAD-filtered independently —
    a rep with a clean min and a noisy max contributes its min and is
    dropped from the max series. Mirrors the squat derivation's
    per-dimension acceptance policy.
    """
    if not reps:
        return None

    min_vals = [r.min_elbow for r in reps if r.min_elbow is not None]
    max_vals = [r.max_elbow for r in reps if r.max_elbow is not None]

    if len(min_vals) < MIN_REPS_REQUIRED or len(max_vals) < MIN_REPS_REQUIRED:
        return None

    kept_min = _mad_reject(min_vals)
    kept_max = _mad_reject(max_vals)

    if len(kept_min) < MIN_REPS_REQUIRED or len(kept_max) < MIN_REPS_REQUIRED:
        return None

    # Group by session for ICC — design-effect correction shrinks the
    # effective n when reps within a session are correlated.
    by_session_min: dict[int, list[float]] = {}
    by_session_max: dict[int, list[float]] = {}
    for r in reps:
        if r.min_elbow is not None:
            by_session_min.setdefault(r.session_idx, []).append(r.min_elbow)
        if r.max_elbow is not None:
            by_session_max.setdefault(r.session_idx, []).append(r.max_elbow)
    _, icc_min, _ = design_effect(by_session_min)
    _, icc_max, _ = design_effect(by_session_max)

    # Point estimates + BCa CIs.
    def stat_bottom(vs: list[float]) -> float:
        return hd_percentile(vs, p_bottom)

    def stat_start(vs: list[float]) -> float:
        return hd_percentile(vs, p_start)

    def stat_end(vs: list[float]) -> float:
        return hd_percentile(vs, P_END_FIXED)

    def stat_shallow(vs: list[float]) -> float:
        return hd_percentile(vs, P_SHALLOW)

    b_lo, b_hi, bottom = bca_ci(kept_min, stat_bottom, n_boot=BOOTSTRAP_RESAMPLES)
    s_lo, s_hi, start = bca_ci(kept_max, stat_start, n_boot=BOOTSTRAP_RESAMPLES)
    e_lo, e_hi, end = bca_ci(kept_max, stat_end, n_boot=BOOTSTRAP_RESAMPLES)
    sh_lo, sh_hi, shallow = bca_ci(
        kept_min, stat_shallow, n_boot=BOOTSTRAP_RESAMPLES
    )

    violations: list[str] = []
    if not (start > end):
        violations.append(
            f"startAngle ({start:.1f}°) must be > endAngle ({end:.1f}°)"
        )
    if not (end > bottom):
        violations.append(
            f"endAngle ({end:.1f}°) must be > bottomAngle ({bottom:.1f}°)"
        )

    n_sessions = len({r.session_idx for r in reps})

    return DerivedPushUpRom(
        p_bottom=p_bottom,
        p_start=p_start,
        n_reps=len(reps),
        n_kept_min=len(kept_min),
        n_kept_max=len(kept_max),
        n_sessions=n_sessions,
        icc_min=icc_min,
        icc_max=icc_max,
        start_angle=start,
        bottom_angle=bottom,
        end_angle=end,
        shallow_rep_max_angle=shallow,
        start_ci=(s_lo, s_hi),
        bottom_ci=(b_lo, b_hi),
        end_ci=(e_lo, e_hi),
        shallow_ci=(sh_lo, sh_hi),
        invariants_ok=len(violations) == 0,
        violations=violations,
    )


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

# Map sweep rows to the Dart sensitivity tier they feed. Single source of
# truth — the renderer reads this to label each block.
_TIER_BY_SWEEP_KEY: dict[tuple[float, float], str] = {
    (15.0, 85.0): "high",
    (10.0, 90.0): "medium (recommended)",
    (5.0, 95.0): "low",
}


def _tier_label(p_bottom: float, p_start: float) -> str:
    return _TIER_BY_SWEEP_KEY.get((p_bottom, p_start), "custom")


def dart_snippet(d: DerivedPushUpRom) -> str:
    """Emit a paste-ready Dart PushUpRomThresholdSet block."""
    inv = "" if d.invariants_ok else "  // ⚠ INVARIANT VIOLATION"
    tier = _tier_label(d.p_bottom, d.p_start)
    lines = [
        f"// P_BOTTOM={d.p_bottom:.0f}, P_START={d.p_start:.0f} — tier: {tier}",
        f"// reps: {d.n_reps} raw, kept_min={d.n_kept_min} "
        f"kept_max={d.n_kept_max}, {d.n_sessions} session(s)",
        f"// ICC_min={d.icc_min:.3f}  ICC_max={d.icc_max:.3f}",
        f"static const PushUpRomThresholdSet _derived = "
        f"PushUpRomThresholdSet({inv}",
        f"  startAngle: {d.start_angle:.1f},  "
        f"// [CI: {d.start_ci[0]:.1f}° – {d.start_ci[1]:.1f}°]",
        f"  bottomAngle: {d.bottom_angle:.1f},  "
        f"// [CI: {d.bottom_ci[0]:.1f}° – {d.bottom_ci[1]:.1f}°]",
        f"  endAngle: {d.end_angle:.1f},  "
        f"// [CI: {d.end_ci[0]:.1f}° – {d.end_ci[1]:.1f}°]",
        f"  shallowRepMaxAngle: {d.shallow_rep_max_angle:.1f},  "
        f"// [CI: {d.shallow_ci[0]:.1f}° – {d.shallow_ci[1]:.1f}°]",
        ");",
    ]
    return "\n".join(lines)


def print_report(d: DerivedPushUpRom) -> None:
    mark = "✅" if d.invariants_ok else "❌"
    tier = _tier_label(d.p_bottom, d.p_start)
    print(f"\n{'=' * 60}")
    print(f"  {mark}  P_BOTTOM={d.p_bottom:.0f}  P_START={d.p_start:.0f}  "
          f"(tier: {tier})")
    print(f"  reps: {d.n_reps} raw → kept_min={d.n_kept_min} "
          f"kept_max={d.n_kept_max}")
    print(f"  sessions: {d.n_sessions}   "
          f"ICC_min={d.icc_min:.3f}   ICC_max={d.icc_max:.3f}")
    print()
    print(f"  startAngle    (P{d.p_start:.0f} of max_elbow) = "
          f"{d.start_angle:>6.1f}°  "
          f"CI [{d.start_ci[0]:.1f}°, {d.start_ci[1]:.1f}°]")
    print(f"  endAngle      (P{P_END_FIXED:.0f} of max_elbow) = "
          f"{d.end_angle:>6.1f}°  "
          f"CI [{d.end_ci[0]:.1f}°, {d.end_ci[1]:.1f}°]")
    print(f"  shallowRepMax (P{P_SHALLOW:.0f} of min_elbow) = "
          f"{d.shallow_rep_max_angle:>6.1f}°  "
          f"CI [{d.shallow_ci[0]:.1f}°, {d.shallow_ci[1]:.1f}°]")
    print(f"  bottomAngle   (P{d.p_bottom:.0f} of min_elbow) = "
          f"{d.bottom_angle:>6.1f}°  "
          f"CI [{d.bottom_ci[0]:.1f}°, {d.bottom_ci[1]:.1f}°]")
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

def _run_analysis(text: str, _args: argparse.Namespace) -> int:
    reps = parse_pushup_rep_lines(text)
    if not reps:
        print("error: no pushup.rep lines found.", file=sys.stderr)
        print("Hints:", file=sys.stderr)
        print("  1. Verify telemetry text contains 'pushup.rep' lines",
              file=sys.stderr)
        print("  2. pushup.rep is always-on; check the input isn't truncated",
              file=sys.stderr)
        return 1

    any_emitted = False
    any_failed = False
    for p_bottom in P_BOTTOM_SWEEP:
        for p_start in P_START_SWEEP:
            # Pair only the tier rows (skip the cross-product cells). The
            # cross-product would emit 9 blocks; only the three diagonal
            # tier rows have a Dart consumer.
            if (p_bottom, p_start) not in _TIER_BY_SWEEP_KEY:
                continue
            result = derive_pushup_thresholds(reps, p_bottom, p_start)
            if result is None:
                continue
            any_emitted = True
            print_report(result)
            if not result.invariants_ok:
                any_failed = True

    if not any_emitted:
        print(
            f"\n⚠  not enough reps in any sweep cell "
            f"(need ≥{MIN_REPS_REQUIRED} per dimension after MAD).",
            file=sys.stderr,
        )
        return 1
    return 1 if any_failed else 0


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Derive push-up ROM FSM thresholds from FiTrack telemetry."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "telemetry_file",
        nargs="?",
        help="Path to telemetry text file. Reads stdin if omitted.",
    )
    parser.add_argument(
        "--out-dir",
        default=str(_DEFAULT_OUT_DIR),
        metavar="DIR",
        help=(
            "Directory to auto-save the derived report into when a file path "
            "is passed as input. Filename: <stem>_pushup_thresholds.txt. "
            "Stdin invocations are NOT auto-saved. "
            f"Default: {_DEFAULT_OUT_DIR}"
        ),
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help=(
            "Disable auto-save even when a file path is passed "
            "(terminal only)."
        ),
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
        out_path = Path(args.out_dir) / f"{in_stem}_pushup_thresholds.txt"
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
            print(f"warning: could not write {out_path}: {e}",
                  file=sys.stderr)
        return exit_code

    return _run_analysis(text, args)


if __name__ == "__main__":
    raise SystemExit(main())
