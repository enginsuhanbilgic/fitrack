"""Derive push-up ROM FSM thresholds from FiTrack debug-session telemetry.

Push-Up Telemetry Threshold Tuning (2026-05-13 Phase 2) +
Unified Pipeline rewrite (2026-05-14 PR B).

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
    One paste-ready Dart ``static const PushUpRomThresholdSet`` block per
    sensitivity tier, mirroring the shape of [PushUpRomDefaults.anchor]
    (High) and the Medium tuple derived via
    [PushUpRomThresholdSet.applySensitivity]. Tier names come from
    `scripts.sensitivity.TIERS` — the Dart `FeedbackSensitivity` enum is
    strictly two-tier (high, medium); see
    `app/test/core/feedback_sensitivity_test.dart`.

METHODOLOGY  (2026-05-14 PR B — unified pipeline)
    Pre-PR-B: percentile sweep — bottom = P10 or P15 of min_elbow, start =
    P85 or P90 of max_elbow, with a fixed shallow gate at P25 that did not
    vary by tier. The sweep was statistically weak at FiTrack's 5–12 reps
    per session, where one rep crossing a boundary could swing the result
    by several degrees.

    Post-PR-B: median anchor + per-tier additive tolerance — matches the
    curl pipeline shape and the doctrine in `.agent_brain/SKILLS.md`
    "Threshold Derivation Pipeline":
      * MAD outlier rejection (3.5 × MAD) per-dimension.
      * `bottom_point  = median_anchor(min_elbow)` (bootstrapped P50)
      * `start_point   = median_anchor(max_elbow)` (bootstrapped P50)
      * For each tier (high, medium):
          - `bottom  = bottom_point + bottom_tolerance`   (looser = shallower)
          - `start   = start_point  - start_tolerance`    (looser = less extension required)
          - `shallow = bottom_point + shallow_tolerance`  (looser = stricter shallow detection)
          - `end     = start - FIXED_END_GAP`             (mirrors curl's fixed end gap)
      * `enforce_ordering` clamps the four-tuple so start > end > shallow > bottom.
      * BCa 95 % bootstrap CI (1 000 resamples) on each anchor.
      * Design-effect (ICC) correction using session as cluster.

    Adding a new tier = adding a row to `PUSHUP_SENSITIVITIES`. Adding a
    new exercise = repeating this pattern with its own SENSITIVITIES dict.

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
"""

from __future__ import annotations

import argparse
import contextlib
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# Shared pipeline modules. PR B (2026-05-14): the math, the tier names, the
# anchor functions, and the invariant clamp all live in dedicated modules
# so every exercise's script reads from the same source of truth. The
# `scripts.derive_thresholds_from_telemetry` import is kept ONLY for the
# `design_effect` re-export (which still lives there under
# `scripts.stats.design_effect` via the curl script's transitive imports).
from scripts.anchors import median_anchor
from scripts.invariants import enforce_ordering
from scripts.sensitivity import TIERS, TIER_SUFFIX
from scripts.stats import (
    BOOTSTRAP_RESAMPLES,
    MAD_REJECTION_THRESHOLD,  # noqa: F401 — re-exported for the test suite
    bca_ci,
    design_effect,
    hd_percentile,
    mad_reject,
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

# Fixed gap between start and end gates. Mirrors curl's `kProfileEndTolerance`
# (start - 20°). End-of-rep extension is a fraction shy of starting
# extension because the user pauses briefly at the top — a tier-independent
# biomechanical fact, not a sensitivity dial.
FIXED_END_GAP = 2.0

# Per-tier tolerances for push-up ROM gates.
#
# **PLACEHOLDER values — telemetry validation pending** (plan §6.2). The
# numbers below were chosen to reproduce the current
# `app/lib/core/push_up_rom_defaults.dart` constants under a *typical*
# user (median elbow ≈ 90° bottom / 167° start). They are NOT derived
# from telemetry; the first push-up session captured under the new
# always-on `pushup.rep` logging line replaces them via a derivation run.
#
# Reasoning for the relative tier gap (the part that IS doctrine-bound):
# - `start_tolerance` tier gap 5°: matches `_mediumLooseness.dStart = -5`.
# - `bottom_tolerance` tier gap 5°: matches `_mediumLooseness.dBottom = +5`.
# - `shallow_tolerance` tier gap 5°: matches `_mediumLooseness.dShallow = +5`.
# All preserved bit-for-bit so PR B's refactor changes the *derivation
# math* without changing the *Dart constants* in flight.
PUSHUP_SENSITIVITIES: dict[str, dict[str, float]] = {
    "high":   {"bottom_tolerance": -5.0, "start_tolerance":  2.0, "shallow_tolerance": 35.0},
    "medium": {"bottom_tolerance":  0.0, "start_tolerance":  7.0, "shallow_tolerance": 40.0},
}


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
# Statistics — `_mad_reject` kept as a back-compat alias for the test suite
# ---------------------------------------------------------------------------

# Pre-PR-B test files import `_mad_reject` directly. Aliasing to the shared
# `mad_reject` keeps those tests passing without a churn-only rename in
# this PR.
_mad_reject = mad_reject


# ---------------------------------------------------------------------------
# Derivation
# ---------------------------------------------------------------------------

@dataclass
class DerivedPushUpRom:
    """One tier's derivation result. Mirrors the shape used by the
    pre-PR-B percentile sweep (same dataclass surface, same field names)
    so the renderer didn't need a rewrite — only the numbers reaching it
    changed.
    """

    tier: str   # "high" | "medium" — from `scripts.sensitivity.TIERS`

    n_reps: int
    n_kept_min: int
    n_kept_max: int
    n_sessions: int
    icc_min: float
    icc_max: float

    # Final FSM gate values for this tier, with tolerances applied and
    # invariant clamps enforced.
    start_angle: float
    bottom_angle: float
    end_angle: float
    shallow_rep_max_angle: float

    # Anchors (point estimates before tolerance) — useful for the report.
    bottom_anchor: float
    start_anchor: float

    # BCa 95 % CIs on the anchors (not the gates).
    bottom_ci: tuple[float, float]
    start_ci: tuple[float, float]

    invariants_ok: bool
    violations: list[str]


def derive_pushup_thresholds(
    reps: list[PushUpRepRecord],
) -> list[DerivedPushUpRom]:
    """Derive a [PushUpRomThresholdSet] tuple per tier.

    Returns one entry per tier in `TIERS` (currently `("high", "medium")`).
    Returns an empty list when either dimension has fewer than
    `MIN_REPS_REQUIRED` kept samples — same floor the squat script applies.

    Pipeline (matches `.agent_brain/SKILLS.md` "Threshold Derivation Pipeline"):
        1. MAD-reject min_elbow and max_elbow rep streams independently.
        2. bottom_point = median_anchor(clean_min) — bootstrapped P50.
        3. start_point  = median_anchor(clean_max) — bootstrapped P50.
        4. For each tier in `TIERS`, apply per-tier tolerances from
           `PUSHUP_SENSITIVITIES`.
        5. `enforce_ordering` clamps the four-tuple to start > end >
           shallow > bottom with a 1° minimum gap.

    Each dimension (min_elbow, max_elbow) is MAD-filtered independently —
    a rep with a clean min and a noisy max contributes its min and is
    dropped from the max series. Mirrors the squat derivation's
    per-dimension acceptance policy.
    """
    if not reps:
        return []

    min_vals = [r.min_elbow for r in reps if r.min_elbow is not None]
    max_vals = [r.max_elbow for r in reps if r.max_elbow is not None]

    if len(min_vals) < MIN_REPS_REQUIRED or len(max_vals) < MIN_REPS_REQUIRED:
        return []

    kept_min = mad_reject(min_vals, threshold=MAD_REJECTION_THRESHOLD)
    kept_max = mad_reject(max_vals, threshold=MAD_REJECTION_THRESHOLD)

    if len(kept_min) < MIN_REPS_REQUIRED or len(kept_max) < MIN_REPS_REQUIRED:
        return []

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

    # Anchors + CIs. `median_anchor` returns just the point estimate;
    # `bca_ci` gives us the CI bounds for the same bootstrapped P50.
    def _p50(vs: list[float]) -> float:
        return hd_percentile(vs, 50.0)

    b_lo, b_hi, bottom_point = bca_ci(
        kept_min, _p50, n_boot=BOOTSTRAP_RESAMPLES,
    )
    s_lo, s_hi, start_point = bca_ci(
        kept_max, _p50, n_boot=BOOTSTRAP_RESAMPLES,
    )
    # Sanity: bca_ci's point estimate is the unbootstrapped `_p50` applied
    # to the kept sample, which is exactly what `median_anchor` returns —
    # this is the doctrine link.
    assert abs(bottom_point - median_anchor(kept_min)) < 1e-9
    assert abs(start_point - median_anchor(kept_max)) < 1e-9

    n_sessions = len({r.session_idx for r in reps})
    n_reps = len(reps)

    results: list[DerivedPushUpRom] = []
    for tier in TIERS:
        tols = PUSHUP_SENSITIVITIES[tier]
        bottom = bottom_point + tols["bottom_tolerance"]
        start = start_point - tols["start_tolerance"]
        shallow = bottom_point + tols["shallow_tolerance"]
        end = start - FIXED_END_GAP

        clamped, violations = enforce_ordering(
            {"start": start, "end": end, "shallow": shallow, "bottom": bottom},
            order=["start", "end", "shallow", "bottom"],
            min_gap=1.0,
        )

        results.append(
            DerivedPushUpRom(
                tier=tier,
                n_reps=n_reps,
                n_kept_min=len(kept_min),
                n_kept_max=len(kept_max),
                n_sessions=n_sessions,
                icc_min=icc_min,
                icc_max=icc_max,
                start_angle=clamped["start"],
                bottom_angle=clamped["bottom"],
                end_angle=clamped["end"],
                shallow_rep_max_angle=clamped["shallow"],
                bottom_anchor=bottom_point,
                start_anchor=start_point,
                bottom_ci=(b_lo, b_hi),
                start_ci=(s_lo, s_hi),
                invariants_ok=len(violations) == 0,
                violations=violations,
            )
        )

    return results


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def dart_snippet(d: DerivedPushUpRom) -> str:
    """Emit a paste-ready Dart PushUpRomThresholdSet block."""
    inv = "" if d.invariants_ok else "  // ⚠ INVARIANT VIOLATION"
    suffix = TIER_SUFFIX.get(d.tier, d.tier.capitalize())
    lines = [
        f"// tier: {d.tier} ({suffix})",
        f"// reps: {d.n_reps} raw, kept_min={d.n_kept_min} "
        f"kept_max={d.n_kept_max}, {d.n_sessions} session(s)",
        f"// ICC_min={d.icc_min:.3f}  ICC_max={d.icc_max:.3f}",
        f"// bottom_anchor={d.bottom_anchor:.1f}° "
        f"start_anchor={d.start_anchor:.1f}°  (median + per-tier tolerance)",
        f"static const PushUpRomThresholdSet _{d.tier} = "
        f"PushUpRomThresholdSet({inv}",
        f"  startAngle: {d.start_angle:.1f},",
        f"  bottomAngle: {d.bottom_angle:.1f},",
        f"  endAngle: {d.end_angle:.1f},",
        f"  shallowRepMaxAngle: {d.shallow_rep_max_angle:.1f},",
        ");",
    ]
    return "\n".join(lines)


def print_report(d: DerivedPushUpRom) -> None:
    mark = "✅" if d.invariants_ok else "❌"
    print(f"\n{'=' * 60}")
    print(f"  {mark}  tier: {d.tier}")
    print(f"  reps: {d.n_reps} raw → kept_min={d.n_kept_min} "
          f"kept_max={d.n_kept_max}")
    print(f"  sessions: {d.n_sessions}   "
          f"ICC_min={d.icc_min:.3f}   ICC_max={d.icc_max:.3f}")
    print()
    print(f"  bottom_anchor (median of min_elbow) = "
          f"{d.bottom_anchor:>6.1f}°  "
          f"CI [{d.bottom_ci[0]:.1f}°, {d.bottom_ci[1]:.1f}°]")
    print(f"  start_anchor  (median of max_elbow) = "
          f"{d.start_anchor:>6.1f}°  "
          f"CI [{d.start_ci[0]:.1f}°, {d.start_ci[1]:.1f}°]")
    print()
    print(f"  startAngle         = {d.start_angle:>6.1f}°")
    print(f"  endAngle           = {d.end_angle:>6.1f}°  "
          f"(= start - {FIXED_END_GAP:.0f}°)")
    print(f"  shallowRepMaxAngle = {d.shallow_rep_max_angle:>6.1f}°")
    print(f"  bottomAngle        = {d.bottom_angle:>6.1f}°")
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

    results = derive_pushup_thresholds(reps)
    if not results:
        print(
            f"\n⚠  not enough reps to derive "
            f"(need ≥{MIN_REPS_REQUIRED} per dimension after MAD).",
            file=sys.stderr,
        )
        return 1

    any_failed = False
    for r in results:
        print_report(r)
        if not r.invariants_ok:
            any_failed = True

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

    # Auto-save discipline: file input ⇒ tee to derived/<stem>_pushup_thresholds.txt
    # unless --no-save. Stdin input never auto-saves (the quick-experiment path).
    if args.telemetry_file and not args.no_save:
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
        stem = Path(args.telemetry_file).stem
        out_path = out_dir / f"{stem}_pushup_thresholds.txt"
        with open(out_path, "w", encoding="utf-8") as f:
            tee = _Tee(sys.stdout, f)
            with contextlib.redirect_stdout(tee):
                rc = _run_analysis(text, args)
        print(f"\n📝  saved to {out_path}")
        return rc

    return _run_analysis(text, args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
