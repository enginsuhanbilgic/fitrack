"""Derive biceps-curl FSM thresholds from FiTrack debug-session telemetry.

INPUT
    A plain-text paste of TelemetryLog entries copied via the Diagnostics
    screen's "Copy all" button. Accepts:
      - a file path as the first CLI argument
      - or stdin (pipe / here-document)

    The paste may contain multiple back-to-back debug sessions from the
    same process lifetime (multi-session paste). The script splits on
    ``curl_debug.session_start`` boundary markers inserted by
    ``WorkoutViewModel.init()`` and processes each session independently
    before pooling.

TWO OPERATING MODES
    Default (rep.extremes mode):
        Reads ``rep.extremes`` lines emitted by the FSM each time a rep
        commits. Requires the FSM thresholds to already be correct enough
        for reps to count — a chicken-and-egg problem for first-time
        side-view calibration.

    --from-frames (frame-signal mode):
        Reads ``pose.frame_metrics`` lines and reconstructs rep boundaries
        from the raw ``angle_raw`` signal using the same local-min/max
        window-extremum detector as Phase B (phase_b_auto_annotate.py).
        Works even when the FSM never counted a single rep — ideal for
        bootstrapping thresholds from a broken-FSM session. The telemetry
        log is already 1€-filtered on-device, so no extra smoothing is
        applied. Debug sessions log at 2 Hz; the dwell guard is scaled
        accordingly (default MIN_DWELL_FRAMES_FRAMES=2 ≈ 1 s).

METHODOLOGY
    Phase D-v2 lineage, with the PR B (2026-05-14) anchor switch:
      * Per-rep extremes from ``rep.extremes`` lines OR frame-signal
        detection (``min=``, ``max=``, ``min_at_peak=`` — wrist-snap
        corrected peak; in frame mode peak = local min, start/end = local maxs)
      * MAD outlier rejection (3.5 × MAD via `scripts.stats.mad_reject`).
      * Median anchor (bootstrapped HD P50) for both peak and start
        angle — matches the doctrine in `.agent_brain/SKILLS.md`
        "Threshold Derivation Pipeline" (ROM gates → median_anchor).
        Pre-PR-B curl used P5(peak) / P95(start) which anchored on the
        user's deepest/most-extended rep; median is more robust at small n.
      * BCa bootstrap CI (1 000 resamples — fewer than v2's 10 000 to keep
        CLI latency under 1 s at n ≈ 15).
      * Design-effect correction using session as cluster (ICC from
        one-way random-effects ANOVA).

GENERALIZATION TOLERANCES  (mirrors manual_rom_overrides.dart provenance)
    peak:       personal median + 28°   (covers users with ~40° peak ROM)
    start:      personal median − 8°    (covers users who only extend to ~145°)
    end:        start − 20°             (mirrors kProfileEndTolerance)
    peakExit:   peak + 15°              (mirrors kCurlPeakExitGap)

OUTPUT
    Terminal report + ready-to-paste Dart snippet for the relevant
    per-exercise `*_rom_defaults.dart` file.

    When a file path is passed as the input (not stdin), the full report
    is ALSO auto-saved to ``data/telemetry/derived/<stem>_thresholds.txt``
    (configurable via --out-dir). Stdin invocations print to terminal
    only — the auto-save is reserved for the "named telemetry session"
    workflow so each derivation has a committed audit artifact.

    Existing derived files are overwritten silently — the input session
    file is the canonical source, so re-running on the same input is
    treated as a deterministic refresh.

USAGE
    # Recommended: named session file → auto-saved derived report.
    python -m scripts.derive_thresholds_from_telemetry \\
        data/telemetry/sessions/2026-05-14_front_right-arm_recalibration.txt --view front
    # → also writes data/telemetry/derived/2026-05-14_front_right-arm_recalibration_thresholds.txt

    # Default mode — requires reps to have been counted by the FSM:
    python -m scripts.derive_thresholds_from_telemetry telemetry.txt
    pbpaste | python -m scripts.derive_thresholds_from_telemetry         # stdin: terminal only

    # Frame-signal mode — works even when FSM never counted a rep:
    python -m scripts.derive_thresholds_from_telemetry --from-frames telemetry.txt
    python -m scripts.derive_thresholds_from_telemetry --from-frames --view sideLeft < log.txt

    # Override view/side labels (useful when session_start header is missing):
    python -m scripts.derive_thresholds_from_telemetry --view sideRight < log.txt

    # Custom output directory (overrides the default data/telemetry/derived/):
    python -m scripts.derive_thresholds_from_telemetry session.txt --out-dir /tmp/derivations
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# Shared pipeline modules (2026-05-14 PR B). The math, the tier names, the
# anchor functions, and the invariant clamp all live in dedicated modules so
# every exercise (curl / squat / push-up) reads from the same source of
# truth. Adding a new exercise = writing a config dict; the helpers below
# do not need to be touched.
from scripts.anchors import median_anchor, p95_anchor  # noqa: F401 — median_anchor re-exported for push-up script
from scripts.invariants import enforce_ordering
from scripts.sensitivity import TIERS, TIER_SUFFIX
from scripts.stats import (
    BOOTSTRAP_RESAMPLES,
    BOOTSTRAP_SEED,
    MAD_REJECTION_THRESHOLD,
    _mad,
    _median,
    bca_ci,
    design_effect,
    hd_percentile,
    mad_reject,
)

# Default location for tee-captured derived reports. Resolved relative to the
# repository root so the script can be invoked from anywhere (the repo is
# determined by walking up from this file's path until 'tools/' is found).
_DEFAULT_OUT_DIR = (
    Path(__file__).resolve().parent.parent / "data" / "telemetry" / "derived"
)

# ---------------------------------------------------------------------------
# Constants — must mirror app/lib/core/constants.dart
# ---------------------------------------------------------------------------

CURL_PEAK_EXIT_GAP_DEG = 15.0   # kCurlPeakExitGap
PROFILE_END_TOLERANCE = 20.0    # kProfileEndTolerance

# Per-tier tolerances for curl ROM gates.
# Keys must match `TIERS` from `scripts.sensitivity` (two-tier rule enforced
# by app/test/core/feedback_sensitivity_test.dart). The dict layout stays
# even after PR B's extraction because tolerances are *per-exercise*; only
# the tier *names* themselves are shared via `TIERS`.
# Values: peak_tolerance added to personal median peak (larger = looser gate);
#         start_tolerance subtracted from personal median start (larger = stricter start).
# 2026-05-14: tolerances loosened (high 20→25/5→7, medium 28→33/8→10) to admit
# borderline reps users were complaining about. Tier gap on peak preserved at 8°.
SENSITIVITIES: dict[str, dict[str, float]] = {
    "high":   {"peak_tolerance": 25.0, "start_tolerance": 7.0},
    "medium": {"peak_tolerance": 33.0, "start_tolerance": 10.0},
}
# Dart field-name suffixes — re-exported from `scripts.sensitivity.TIER_SUFFIX`
# under the old name for backward compatibility with the in-file consumers
# below. New code reads `TIER_SUFFIX` directly.
_SENSITIVITY_SUFFIX: dict[str, str] = TIER_SUFFIX

# Minimum reps needed to produce a threshold estimate
MIN_REPS_REQUIRED = 5

# ---------------------------------------------------------------------------
# Telemetry parsing
# ---------------------------------------------------------------------------

# rep.extremes line example:
# [2026-04-27T10:23:11.123] rep.extremes: rep=3 min=24.5 max=158.2 rom=133.7
#   concentric_ms=1200 min_at_peak=22.1 side=right arm=right view=sideRight
_RE_REP_EXTREMES = re.compile(
    r"rep\.extremes:.*?"
    r"rep=(\d+).*?"
    r"min=([\d.]+).*?"
    r"max=([\d.]+).*?"
    r"min_at_peak=([\d.]+)"
)

# session_start line example:
# [2026-04-27T10:20:00.000] curl_debug.session_start: ts=... exercise=bicepsCurlSide
#   side=right view=sideRight thresholds_start=160.0 ...
_RE_SESSION_START = re.compile(r"curl_debug\.session_start:")
_RE_SESSION_VIEW = re.compile(r"view=(\S+)")
_RE_SESSION_SIDE = re.compile(r"\bside=(\S+)")


@dataclass
class RepRecord:
    rep_idx: int
    trough_angle: float    # min= (maximum elbow extension during rep)
    peak_angle: float      # min_at_peak= (corrected peak; lower angle = more curl)
    start_angle: float     # max= (arm angle at rep start ≈ extension)


@dataclass
class SessionBlock:
    session_idx: int       # 1-based session number within the paste
    view: str              # e.g. "sideRight", "sideLeft", "front"
    side: str              # e.g. "right", "left"
    reps: list[RepRecord] = field(default_factory=list)


def _parse_sessions(text: str) -> list[SessionBlock]:
    """Split telemetry text on session_start markers and parse rep.extremes."""
    lines = text.splitlines()

    # Identify session boundary line indices
    boundary_indices: list[int] = []
    for i, line in enumerate(lines):
        if _RE_SESSION_START.search(line):
            boundary_indices.append(i)

    # If no session markers, treat the entire paste as one anonymous session
    if not boundary_indices:
        boundary_indices = [-1]  # sentinel: "header" starts before line 0

    sessions: list[SessionBlock] = []
    for seq, start_line in enumerate(boundary_indices):
        # Determine end of this session's block
        end_line = (
            boundary_indices[seq + 1]
            if seq + 1 < len(boundary_indices)
            else len(lines)
        )

        # Extract view and side from the session_start header (if present)
        view = "unknown"
        side = "unknown"
        if start_line >= 0:
            header = lines[start_line]
            vm = _RE_SESSION_VIEW.search(header)
            sm = _RE_SESSION_SIDE.search(header)
            if vm:
                view = vm.group(1)
            if sm:
                side = sm.group(1)

        block = SessionBlock(session_idx=seq + 1, view=view, side=side)

        for line in lines[start_line + 1 : end_line]:
            m = _RE_REP_EXTREMES.search(line)
            if m:
                block.reps.append(
                    RepRecord(
                        rep_idx=int(m.group(1)),
                        trough_angle=float(m.group(2)),
                        peak_angle=float(m.group(4)),   # min_at_peak (corrected)
                        start_angle=float(m.group(3)),  # max (extension)
                    )
                )

        sessions.append(block)

    return sessions


# ---------------------------------------------------------------------------
# Frame-signal rep detection (--from-frames mode)
# ---------------------------------------------------------------------------

# pose.frame_metrics line example:
# [2026-04-28T04:20:08.713622] pose.frame_metrics: fsm=concentric angle_raw=111.3 ...
_RE_FRAME_METRICS = re.compile(r"pose\.frame_metrics:.*?angle_raw=([\d.]+)")

# At 2 Hz debug logging (ring_buffer=2000, logged at 2.0Hz per session header),
# 2 consecutive frames ≈ 1 second — sufficient dwell to reject chatter without
# suppressing real rep boundaries. Phase B uses 8 at ~30 fps (≈ 0.27 s); we
# scale to ~1 s because the 2 Hz signal is already 1€-filtered on-device and
# therefore much smoother.
_FRAMES_MIN_DWELL = 2

# Minimum angle excursion per detected rep (mirrors kCalibrationMinExcursion).
_FRAMES_MIN_EXCURSION = 40.0


def _parse_frame_sessions(text: str) -> list[SessionBlock]:
    """Parse pose.frame_metrics angle_raw series and detect reps via local extrema.

    In the Diagnostics "Copy all" export the log is newest-first, which means
    ``curl_debug.session_start`` appears as the LAST line of each session block
    (not the first). The frame_metrics lines for a given session are the lines
    that appear ABOVE (i.e., before in file order) the session_start marker.

    For N sessions the file layout looks like:
        [frame lines for session N]   ← most recent, at top of file
        curl_debug.session_start (session N)
        [frame lines for session N-1]
        curl_debug.session_start (session N-1)
        ...
        app.bootstrap

    So the slice for session k is lines[prev_session_start+1 : this_session_start],
    reversed to restore chronological order, then fed to the extremum detector.
    """
    lines = text.splitlines()

    # Identify session boundary indices (session_start acts as a footer here)
    boundary_indices: list[int] = []
    for i, line in enumerate(lines):
        if _RE_SESSION_START.search(line):
            boundary_indices.append(i)

    if not boundary_indices:
        # No session markers — treat the whole paste as one anonymous session
        boundary_indices = [len(lines)]  # sentinel footer at end

    sessions: list[SessionBlock] = []
    for seq, footer_line in enumerate(boundary_indices):
        # Frame lines for this session are above this footer and below the
        # previous session's footer (or the start of the file for the first).
        prev_footer = boundary_indices[seq - 1] + 1 if seq > 0 else 0
        session_slice = lines[prev_footer:footer_line]

        view = "unknown"
        side = "unknown"
        if footer_line < len(lines):
            header = lines[footer_line]
            vm = _RE_SESSION_VIEW.search(header)
            sm = _RE_SESSION_SIDE.search(header)
            if vm:
                view = vm.group(1)
            if sm:
                side = sm.group(1)

        block = SessionBlock(session_idx=seq + 1, view=view, side=side)

        # session_slice is newest-first; reverse to get chronological order.
        frame_angles: list[float] = []
        for line in reversed(session_slice):
            m = _RE_FRAME_METRICS.search(line)
            if m:
                frame_angles.append(float(m.group(1)))

        if len(frame_angles) < 4:
            sessions.append(block)
            continue

        # Detect rep triples from the chronological angle series.
        triples = _detect_reps_from_angles(
            frame_angles,
            min_excursion=_FRAMES_MIN_EXCURSION,
            min_dwell_frames=_FRAMES_MIN_DWELL,
        )

        for rep_idx, (s_idx, p_idx, e_idx) in enumerate(triples):
            s_angle = frame_angles[s_idx]
            p_angle = frame_angles[p_idx]
            e_angle = frame_angles[e_idx]
            block.reps.append(
                RepRecord(
                    rep_idx=rep_idx + 1,
                    # peak_angle = local min (most flexed point)
                    peak_angle=p_angle,
                    # start_angle = local max at rep start (most extended)
                    start_angle=s_angle,
                    # trough_angle = local max at rep end (return to extension)
                    trough_angle=e_angle,
                )
            )

        sessions.append(block)

    return sessions


def _detect_reps_from_angles(
    angles: list[float],
    *,
    min_excursion: float = _FRAMES_MIN_EXCURSION,
    min_dwell_frames: int = _FRAMES_MIN_DWELL,
) -> list[tuple[int, int, int]]:
    """Find (start_idx, peak_idx, end_idx) index triples in a chronological
    angle series using the same window-extremum algorithm as Phase B.

    A rep is a (local-max, local-min, local-max) triple where the excursion
    (max(start_angle, end_angle) - peak_angle) >= min_excursion.
    """
    n = len(angles)
    if n < 3:
        return []

    # Build extrema list: (index, angle, kind) where kind=+1 is local max, -1 is local min.
    extrema: list[tuple[int, float, int]] = []
    direction = 0
    last_flip_idx = 0
    pending_kind = 0
    pending_idx = 0
    pending_angle = angles[0]

    for i in range(1, n):
        angle = angles[i]
        prev_angle = angles[i - 1]
        if angle > prev_angle:
            new_dir = +1
        elif angle < prev_angle:
            new_dir = -1
        else:
            new_dir = direction

        if direction == 0:
            direction = new_dir
            pending_idx = i - 1
            pending_angle = prev_angle
            pending_kind = -1 if new_dir == +1 else +1
            last_flip_idx = i - 1
            continue

        if new_dir != 0 and new_dir != direction:
            flip_idx = i - 1
            flip_angle = prev_angle
            flip_kind = +1 if direction == +1 else -1
            if flip_idx - last_flip_idx >= min_dwell_frames:
                extrema.append((pending_idx, pending_angle, pending_kind))
                pending_idx = flip_idx
                pending_angle = flip_angle
                pending_kind = flip_kind
                last_flip_idx = flip_idx
                direction = new_dir

    # Close out
    extrema.append((pending_idx, pending_angle, pending_kind))
    if direction != 0:
        last_idx = n - 1
        terminal_kind = +1 if direction == +1 else -1
        if last_idx - last_flip_idx >= min_dwell_frames and last_idx != pending_idx:
            extrema.append((last_idx, angles[last_idx], terminal_kind))

    # Walk for (max, min, max) triples
    reps: list[tuple[int, int, int]] = []
    i = 0
    while i + 2 < len(extrema):
        s_idx, s_angle, s_kind = extrema[i]
        p_idx, p_angle, p_kind = extrema[i + 1]
        e_idx, e_angle, e_kind = extrema[i + 2]
        if s_kind == +1 and p_kind == -1 and e_kind == +1:
            excursion = max(s_angle, e_angle) - p_angle
            if excursion >= min_excursion:
                reps.append((s_idx, p_idx, e_idx))
                i += 2
                continue
        i += 1

    return reps


# ---------------------------------------------------------------------------
# Statistics — moved to `scripts.stats` in 2026-05-14 PR B so push-up and
# any future exercise share the same math without re-importing this script.
# `bca_ci`, `hd_percentile`, `mad_reject`, `design_effect`,
# `MAD_REJECTION_THRESHOLD`, `BOOTSTRAP_RESAMPLES`, and `BOOTSTRAP_SEED` are
# imported at the top of this file (and re-exported as module attributes)
# so call sites that did `from scripts.derive_thresholds_from_telemetry
# import bca_ci` keep working.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Threshold derivation
# ---------------------------------------------------------------------------

@dataclass
class DerivedThresholds:
    sensitivity: str   # "high" | "medium"  (two-tier rule, 2026-05-14)
    view: str
    side: str
    n_reps: int
    n_reps_after_rejection: int
    n_sessions: int
    effective_n: int
    icc: float
    deff: float

    # personal medians (before tolerances)
    median_peak_deg: float
    median_start_deg: float

    # FSM threshold values (after generalization tolerances)
    start_angle: float
    peak_angle: float
    peak_exit_angle: float
    end_angle: float

    # 95 % BCa CI on the personal medians
    start_ci: tuple[float, float]
    peak_ci: tuple[float, float]

    invariants_ok: bool
    invariant_violations: list[str]


def _derive(
    sessions: list[SessionBlock],
    view_override: Optional[str],
    side_override: Optional[str],
) -> Optional[list[DerivedThresholds]]:
    """Return one DerivedThresholds per sensitivity level, or None if too few reps."""
    # Collect all reps, optionally filtering by view/side
    all_reps: list[RepRecord] = []

    candidate_view = view_override or "unknown"
    candidate_side = side_override or "unknown"

    for s in sessions:
        effective_view = view_override or s.view
        effective_side = side_override or s.side
        if candidate_view == "unknown":
            candidate_view = effective_view
        if candidate_side == "unknown":
            candidate_side = effective_side

        if view_override and s.view != "unknown" and s.view != view_override:
            continue
        if side_override and s.side != "unknown" and s.side != side_override:
            continue

        all_reps.extend(s.reps)

    n_total = len(all_reps)
    if n_total < MIN_REPS_REQUIRED:
        return None

    raw_peaks = [r.peak_angle for r in all_reps]
    raw_starts = [r.start_angle for r in all_reps]

    # MAD outlier rejection — computed once, shared across all sensitivity levels
    med_p = _median(raw_peaks)
    mad_p = _mad(raw_peaks)
    med_s = _median(raw_starts)
    mad_s = _mad(raw_starts)

    def _keep(r: RepRecord) -> bool:
        peak_ok = (mad_p == 0) or (abs(r.peak_angle - med_p) / mad_p <= MAD_REJECTION_THRESHOLD)
        start_ok = (mad_s == 0) or (abs(r.start_angle - med_s) / mad_s <= MAD_REJECTION_THRESHOLD)
        return peak_ok and start_ok

    kept = [r for r in all_reps if _keep(r)]
    n_kept = len(kept)
    if n_kept < MIN_REPS_REQUIRED:
        return None

    kept_peaks = [r.peak_angle for r in kept]
    kept_starts = [r.start_angle for r in kept]

    # Design effect using session as cluster — computed once
    by_session_kept: dict[int, list[float]] = {}
    for r in kept:
        for s in sessions:
            if r in s.reps:
                by_session_kept.setdefault(s.session_idx, []).append(r.peak_angle)
                break
    deff, icc, eff_n = design_effect(by_session_kept)

    # Median anchor (PR B, 2026-05-14): both peak and start anchor on the
    # bootstrapped median of the user's reps — the user's *typical* depth
    # and *typical* extension. Tolerance constants in SENSITIVITIES are
    # added (peak) or subtracted (start) to admit borderline reps.
    #
    # Pre-2026-05-14 curl used BCa(P5) for peak and BCa(P95) for start —
    # i.e. the user's deepest/most-extended rep + small tolerance. That
    # anchored on the extreme, which is more sensitive to a single
    # outlier at FiTrack's typical n=8–12 reps/session. Median anchoring
    # matches clinical biomechanics convention (Reese & Bandy, FMS) and
    # the doctrine in `.agent_brain/SKILLS.md` "Threshold Derivation
    # Pipeline".
    #
    # The CI is computed by BCa wrapping the same Harrell-Davis median
    # estimator, so the reported `*_ci` bounds reflect the actual
    # statistic used as the anchor (not the old P5/P95 picks).
    def stat_median(vs: list[float]) -> float:
        return hd_percentile(vs, 50.0)

    peak_ci_lo, peak_ci_hi, peak_point = bca_ci(kept_peaks, stat_median)
    start_ci_lo, start_ci_hi, start_point = bca_ci(kept_starts, stat_median)

    # Apply each sensitivity tier's tolerances independently. `TIERS` from
    # `scripts.sensitivity` is the single source of truth for which tiers
    # exist; iterating it (instead of `SENSITIVITIES.items()`) means adding
    # a new tier requires touching `scripts.sensitivity` *and* the per-
    # exercise `SENSITIVITIES` dict in lock-step — the lookup error here
    # surfaces the omission immediately.
    results: list[DerivedThresholds] = []
    for tier in TIERS:
        tols = SENSITIVITIES[tier]
        peak_tol = tols["peak_tolerance"]
        start_tol = tols["start_tolerance"]

        peak_threshold = peak_point + peak_tol
        start_threshold = start_point - start_tol
        peak_exit_threshold = peak_threshold + CURL_PEAK_EXIT_GAP_DEG
        # Guarantee FSM invariant: start > end > peakExit > peak.
        # The nominal end = start - 20° can fall below peakExit when tolerances are
        # large (e.g. side-view with +28° peak tolerance). In that case, raise end
        # to peakExit + 5° so the invariant holds. If even that would violate
        # start > end, the data is geometrically inconsistent — clamp and let the
        # invariant checker report it.
        nominal_end = start_threshold - PROFILE_END_TOLERANCE
        end_threshold = max(nominal_end, peak_exit_threshold + 5.0)
        end_threshold = min(end_threshold, start_threshold - 1.0)

        violations: list[str] = []
        if not (start_threshold > end_threshold):
            violations.append(
                f"start ({start_threshold:.1f}°) must be > end ({end_threshold:.1f}°)"
            )
        if not (end_threshold > peak_exit_threshold):
            violations.append(
                f"end ({end_threshold:.1f}°) must be > peakExit ({peak_exit_threshold:.1f}°)"
            )
        if not (peak_exit_threshold > peak_threshold):
            violations.append(
                f"peakExit ({peak_exit_threshold:.1f}°) must be > peak ({peak_threshold:.1f}°)"
            )
        if not (peak_threshold < start_threshold):
            violations.append(
                f"peak ({peak_threshold:.1f}°) must be < start ({start_threshold:.1f}°)"
            )

        results.append(DerivedThresholds(
            sensitivity=tier,
            view=candidate_view,
            side=candidate_side,
            n_reps=n_total,
            n_reps_after_rejection=n_kept,
            n_sessions=len(sessions),
            effective_n=eff_n,
            icc=icc,
            deff=deff,
            median_peak_deg=peak_point,
            median_start_deg=start_point,
            start_angle=start_threshold,
            peak_angle=peak_threshold,
            peak_exit_angle=peak_exit_threshold,
            end_angle=end_threshold,
            start_ci=(start_ci_lo - start_tol, start_ci_hi - start_tol),
            peak_ci=(peak_ci_lo + peak_tol, peak_ci_hi + peak_tol),
            invariants_ok=len(violations) == 0,
            invariant_violations=violations,
        ))

    return results


# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

def _dart_field_base(view: str, side: str) -> str:
    """Map (view, side) to the ManualRomOverrides field base name (no suffix)."""
    v = view.lower()
    if "front" in v:
        return "front"
    if "left" in v or side.lower() == "left":
        return "sideLeft"
    if "right" in v or side.lower() == "right":
        return "sideRight"
    return "unknownView"


def _dart_snippets(results: list[DerivedThresholds]) -> str:
    """Emit two named constants (Strict / Default) for one view.

    Two-tier rule (2026-05-14, PR A): a `Permissive` block is no longer
    emitted — the Dart `FeedbackSensitivity` enum has no `low` value.
    """
    if not results:
        return ""
    first = results[0]
    base = _dart_field_base(first.view, first.side)
    lines = [
        f"  // Derived {first.view} — {first.n_reps_after_rejection} reps "
        f"(of {first.n_reps} raw), {first.n_sessions} session(s)",
        f"  // ICC={first.icc:.3f}  deff={first.deff:.2f}  eff_n={first.effective_n}",
        f"  // personal median: peak={first.median_peak_deg:.1f}°  "
        f"start={first.median_start_deg:.1f}°",
    ]
    for r in results:
        suffix = _SENSITIVITY_SUFFIX.get(r.sensitivity, r.sensitivity.capitalize())
        tols = SENSITIVITIES[r.sensitivity]
        inv = "" if r.invariants_ok else "  // ⚠ INVARIANT VIOLATION"
        lines += [
            f"",
            f"  /// {r.sensitivity.upper()} sensitivity "
            f"(peak_tol +{tols['peak_tolerance']:.0f}°, start_tol −{tols['start_tolerance']:.0f}°){inv}",
            f"  static const CurlRomThresholdSet {base}{suffix} = CurlRomThresholdSet(",
            f"    startAngle: {r.start_angle:.1f},",
            f"    peakAngle: {r.peak_angle:.1f},",
            f"    peakExitAngle: {r.peak_exit_angle:.1f},",
            f"    endAngle: {r.end_angle:.1f},",
            f"  );",
        ]
    return "\n".join(lines)


def _print_report(results: list[DerivedThresholds], verbose: bool) -> None:
    if not results:
        return
    first = results[0]
    all_ok = all(r.invariants_ok for r in results)
    inv_mark = "✅" if all_ok else "❌"
    print(f"\n{'='*60}")
    print(f"  {inv_mark}  view={first.view}  side={first.side}")
    print(f"  reps: {first.n_reps} raw → {first.n_reps_after_rejection} kept "
          f"({first.n_reps - first.n_reps_after_rejection} rejected by MAD)")
    print(f"  sessions: {first.n_sessions}   ICC={first.icc:.3f}   "
          f"deff={first.deff:.2f}   eff_n={first.effective_n}")
    print()
    print("  Median anchors (bootstrapped HD P50 before tolerances) — PR B doctrine:")
    print(f"    peak  (median of peak_angle)  = {first.median_peak_deg:>6.1f}°  "
          f"CI [{first.peak_ci[0]:.1f}°, {first.peak_ci[1]:.1f}°]")
    print(f"    start (median of start_angle) = {first.median_start_deg:>6.1f}°  "
          f"CI [{first.start_ci[0]:.1f}°, {first.start_ci[1]:.1f}°]")
    print()

    # Sensitivity comparison table
    col = 10
    header = f"  {'Threshold':<16}" + "".join(f"{r.sensitivity.upper():>{col}}" for r in results)
    print(header)
    print(f"  {'─'*16}" + ("─"*col) * len(results))
    rows = [
        ("startAngle",    [r.start_angle for r in results]),
        ("endAngle",      [r.end_angle for r in results]),
        ("peakExitAngle", [r.peak_exit_angle for r in results]),
        ("peakAngle",     [r.peak_angle for r in results]),
    ]
    for label, vals in rows:
        row = f"  {label:<16}" + "".join(f"{v:>{col}.1f}" for v in vals)
        print(row)
    print()

    for r in results:
        if r.invariant_violations:
            print(f"  ⚠  INVARIANT VIOLATIONS ({r.sensitivity}):")
            for v in r.invariant_violations:
                print(f"      • {v}")

    print()
    print("  ── Dart snippet ─────────────────────────────────────")
    print(_dart_snippets(results))
    print("  ─────────────────────────────────────────────────────")


# ---------------------------------------------------------------------------
# Session summary table
# ---------------------------------------------------------------------------

def _print_session_table(sessions: list[SessionBlock]) -> None:
    print("\nParsed sessions:")
    print(f"  {'#':>3}  {'view':<12}  {'side':<8}  {'reps':>4}")
    print(f"  {'─'*3}  {'─'*12}  {'─'*8}  {'─'*4}")
    for s in sessions:
        print(f"  {s.session_idx:>3}  {s.view:<12}  {s.side:<8}  {len(s.reps):>4}")
    total = sum(len(s.reps) for s in sessions)
    print(f"  {'─'*3}  {'─'*12}  {'─'*8}  {'─'*4}")
    print(f"  {'':>3}  {'total':<12}  {'':8}  {total:>4}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Squat constants — mirror app/lib/core/constants.dart
# ---------------------------------------------------------------------------

SQUAT_LEAN_WARN_BODYWEIGHT = 45.0
SQUAT_LEAN_WARN_HBBS = 50.0
SQUAT_KNEE_SHIFT_WARN = 0.30
SQUAT_HEEL_LIFT_WARN = 0.03

# 2026-05-14 — Sensitivity vs Form Audit doctrine split.
# See .agent_brain/SKILLS.md → "Sensitivity vs Form Audit". Form-audit
# thresholds (lean / shift / lift) no longer vary by tier; only ROM does.
# Squat has no ROM tier dict here — squat ROM derivation (when added) lives
# in a future workflow. The form-audit dict is the entire squat surface today.

# Form-audit tolerance — single fixed config, NOT tier-keyed.
# Values match the previous `medium` row so existing medium users see no
# behavior change; high users get marginally more lenient form warnings
# (the corrected behavior — pre-2026-05-14 high was the safety inversion).
SQUAT_FORM_AUDIT_CONFIG: dict[str, float] = {
    "lean_tol":  5.0,
    "shift_tol": 0.05,
    "lift_tol":  0.008,
}


# ---------------------------------------------------------------------------
# Squat data classes
# ---------------------------------------------------------------------------

@dataclass
class DerivedSquatThresholds:
    sensitivity: str
    variant: str            # 'bodyweight' | 'highBarBackSquat'
    lean_warn_deg: float
    knee_shift_warn: float
    heel_lift_warn: float
    lean_n: int
    shift_n: int
    lift_n: int
    invariants_ok: bool
    violations: list[str]


# ---------------------------------------------------------------------------
# Squat telemetry parser
# ---------------------------------------------------------------------------

_SQUAT_REP_RE = re.compile(
    r"squat\.rep\s+"
    r"rep=\d+\s+"
    r"variant=(?P<variant>\S+)\s+"
    r"long_femur=(?P<long_femur>\S+)\s+"
    r"lean_deg=(?P<lean_deg>[0-9.]+|null)\s+"
    r"knee_shift=(?P<knee_shift>[0-9.]+|null)\s+"
    r"heel_lift=(?P<heel_lift>[0-9.]+|null)\s+"
    r"quality=(?P<quality>[0-9.]+|null)"
)


def _parse_squat_sessions(text: str) -> list[dict]:
    """Return list of rep dicts parsed from squat.rep telemetry lines.

    squat.rep is always-logged (not gated on debug session), so production
    logs without squat_debug.session_start markers are also handled: in that
    case blocks[1:] is empty and the function returns [].
    """
    reps: list[dict] = []
    session_idx = 0
    blocks = text.split("squat_debug.session_start")
    for block in blocks[1:]:   # skip pre-first-session text
        session_idx += 1
        for m in _SQUAT_REP_RE.finditer(block):
            lean = m.group("lean_deg")
            shift = m.group("knee_shift")
            lift = m.group("heel_lift")
            quality = m.group("quality")
            reps.append({
                "session": session_idx,
                "variant": m.group("variant"),
                "long_femur": m.group("long_femur") == "true",
                "lean_deg": float(lean) if lean != "null" else None,
                "knee_shift": float(shift) if shift != "null" else None,
                "heel_lift": float(lift) if lift != "null" else None,
                "quality": float(quality) if quality != "null" else None,
            })
    return reps


# ---------------------------------------------------------------------------
# Squat threshold derivation
# ---------------------------------------------------------------------------

def _derive_squat_form_audit(
    reps: list[dict],
    variant_filter: Optional[str] = None,
) -> Optional[DerivedSquatThresholds]:
    """Derive squat **form-audit** thresholds — a single fixed result, NOT tier-keyed.

    Per the Sensitivity vs Form Audit doctrine (.agent_brain/SKILLS.md, 2026-05-14),
    form-audit values are biomechanical truth, not user preference. The Python
    script no longer emits one block per tier; it emits one block, full stop.

    variant_filter: 'bodyweight' | 'highBarBackSquat' | None (all variants).
    Returns None when there are fewer than 10 reps with lean data.
    """
    filtered = [r for r in reps if r["lean_deg"] is not None]
    if variant_filter:
        filtered = [r for r in filtered if r["variant"] == variant_filter]
    if len(filtered) < 10:
        print(f"  ⚠  insufficient data for {variant_filter or 'all'}: {len(filtered)} reps")
        return None

    lean_vals  = [r["lean_deg"]   for r in filtered if r["lean_deg"]   is not None]
    shift_vals = [r["knee_shift"] for r in filtered if r["knee_shift"] is not None]
    lift_vals  = [r["heel_lift"]  for r in filtered if r["heel_lift"]  is not None]

    # MAD rejection (same 3.5× threshold as curl pipeline)
    lean_clean  = mad_reject(lean_vals)
    shift_clean = mad_reject(shift_vals)
    lift_clean  = mad_reject(lift_vals)

    # P95 anchor (PR B, 2026-05-14): fault upper bound — threshold covers
    # ~95% of population reps. Pre-PR-B these calls passed `0.95` as the
    # percentile, but `hd_percentile` expects PERCENT (0..100), not fraction
    # (0..1) — so the pre-PR-B squat form-audit derivation was effectively
    # asking for the 0.95th percentile (i.e. near the minimum) and producing
    # absurdly tight gates. Switching to `p95_anchor`, which internally
    # calls `hd_percentile(values, 95.0)`, both fixes that latent bug and
    # gives squat the same shared anchor doctrine as curl/push-up. See
    # `.agent_brain/SKILLS.md` "Threshold Derivation Pipeline" doctrine.
    lean_p95  = p95_anchor(lean_clean)
    shift_p95 = p95_anchor(shift_clean)
    lift_p95  = p95_anchor(lift_clean)

    tols = SQUAT_FORM_AUDIT_CONFIG
    lean_thresh  = lean_p95  + tols["lean_tol"]
    shift_thresh = shift_p95 + tols["shift_tol"]
    lift_thresh  = lift_p95  + tols["lift_tol"]

    # No FSM ordering invariant for squat form audit — thresholds are independent
    violations: list[str] = []
    if lean_thresh <= 0:
        violations.append("lean_thresh must be > 0")
    if shift_thresh <= 0:
        violations.append("shift_thresh must be > 0")
    if lift_thresh <= 0:
        violations.append("lift_thresh must be > 0")

    return DerivedSquatThresholds(
        # Sentinel name; form audit is untiered. Kept on the dataclass for the
        # report formatter's column compatibility with curl's tiered output.
        sensitivity="fixed",
        variant=variant_filter or "all",
        lean_warn_deg=round(lean_thresh, 1),
        knee_shift_warn=round(shift_thresh, 4),
        heel_lift_warn=round(lift_thresh, 4),
        lean_n=len(lean_clean),
        shift_n=len(shift_clean),
        lift_n=len(lift_clean),
        invariants_ok=len(violations) == 0,
        violations=violations,
    )


# ---------------------------------------------------------------------------
# Squat output helpers
# ---------------------------------------------------------------------------

def _dart_squat_snippet(result: DerivedSquatThresholds, variant: str) -> str:
    """Emit a Dart snippet for the FIXED squat form-audit thresholds.

    Form audit is untiered (Sensitivity vs Form Audit doctrine, 2026-05-14).
    The snippet maps to constants in `app/lib/core/squat_form_audit_defaults.dart`.
    """
    variant_suffix = variant.title().replace('_', '')
    return "\n".join([
        f"// Squat form-audit thresholds derived from telemetry — variant: {variant}",
        f"// Fixed (no sensitivity tier) per Sensitivity vs Form Audit doctrine.",
        f"// n={result.lean_n} reps after MAD rejection.",
        f"const double kSquatLeanWarnDeg{variant_suffix} = {result.lean_warn_deg};",
        f"const double kSquatKneeShiftWarnRatio = {result.knee_shift_warn};",
        f"const double kSquatHeelLiftWarnRatio = {result.heel_lift_warn};",
    ])


def _print_squat_report(result: DerivedSquatThresholds, variant: str) -> None:
    print(f"\n{'─'*60}")
    print(f"  Squat form-audit thresholds — {variant} (fixed; untiered)")
    print(f"{'─'*60}")
    header = f"{'Lean (°)':<12} {'Knee shift':<14} {'Heel lift':<12} N"
    print(header)
    print("─" * len(header))
    flag = "" if result.invariants_ok else " ⚠ VIOLATION"
    print(
        f"{result.lean_warn_deg:<12.1f} "
        f"{result.knee_shift_warn:<14.4f} "
        f"{result.heel_lift_warn:<12.4f} "
        f"{result.lean_n}{flag}"
    )
    print()


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Derive FSM thresholds from FiTrack debug-session telemetry.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "telemetry_file",
        nargs="?",
        help="Path to telemetry text file. Reads stdin if omitted.",
    )
    parser.add_argument(
        "--from-frames",
        action="store_true",
        help=(
            "Detect rep boundaries from pose.frame_metrics angle_raw series "
            "instead of rep.extremes lines. Use this when the FSM never counted "
            "reps (broken thresholds) — the detector finds local minima/maxima "
            "in the raw angle signal, so no committed reps are needed."
        ),
    )
    parser.add_argument(
        "--exercise",
        choices=["curl", "squat", "all"],
        default="curl",
        help="Which exercise telemetry to analyse (default: curl for backwards compat).",
    )
    parser.add_argument(
        "--view",
        help="Force a specific view label (e.g. sideRight) — useful when the "
             "session_start header is missing.",
    )
    parser.add_argument(
        "--side",
        help="Force a specific side label (e.g. right).",
    )
    parser.add_argument(
        "--mad-threshold",
        type=float,
        default=MAD_REJECTION_THRESHOLD,
        metavar="T",
        help=f"MAD outlier rejection threshold (default {MAD_REJECTION_THRESHOLD}).",
    )
    parser.add_argument(
        "--min-reps",
        type=int,
        default=MIN_REPS_REQUIRED,
        metavar="N",
        help=f"Minimum reps required to derive thresholds (default {MIN_REPS_REQUIRED}).",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Show per-session breakdown.",
    )
    parser.add_argument(
        "--out-dir",
        default=str(_DEFAULT_OUT_DIR),
        metavar="DIR",
        help=(
            "Directory to auto-save the derived report into when a file path "
            "is passed as input. Filename is derived from the input stem: "
            "<stem>_thresholds.txt. Stdin invocations are NOT auto-saved. "
            f"Default: {_DEFAULT_OUT_DIR}"
        ),
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Disable auto-save even when a file path is passed (terminal only).",
    )
    args = parser.parse_args(argv)

    # Read input
    if args.telemetry_file:
        try:
            text = open(args.telemetry_file, encoding="utf-8").read()
        except OSError as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
    else:
        text = sys.stdin.read()

    if not text.strip():
        print("error: no input — paste telemetry text or provide a file path.",
              file=sys.stderr)
        return 2

    # Compute auto-save destination (only when input is a file path AND --no-save not set).
    out_path: Optional[Path] = None
    if args.telemetry_file and not args.no_save:
        in_stem = Path(args.telemetry_file).stem
        out_path = Path(args.out_dir) / f"{in_stem}_thresholds.txt"
        try:
            out_path.parent.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            print(f"warning: could not create output dir {out_path.parent}: {e}",
                  file=sys.stderr)
            out_path = None

    # Run the analysis. If auto-save is active, tee stdout to both terminal and file.
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


class _Tee:
    """Minimal write-only file-like object that forwards writes to multiple streams.

    Used by main() to mirror stdout to both the terminal and an in-memory buffer
    when auto-save is active. Implements only the methods Python's print() needs.
    """

    def __init__(self, *streams):
        self._streams = streams

    def write(self, data):
        for s in self._streams:
            s.write(data)

    def flush(self):
        for s in self._streams:
            s.flush()


def _run_analysis(text: str, args: argparse.Namespace) -> int:
    """Body of the original main(), extracted so the auto-save wrapper can call it
    under contextlib.redirect_stdout. Reads parsed args + already-loaded telemetry
    text; returns the same exit codes the original main() did.
    """

    # ── Squat analysis ──────────────────────────────────────────────────────
    if args.exercise in ("squat", "all"):
        squat_reps = _parse_squat_sessions(text)
        if not squat_reps:
            print("No squat.rep lines found in telemetry (need squat_debug.session_start markers).")
            if args.exercise == "squat":
                return 1
        else:
            squat_any_failed = False
            for variant in ("bodyweight", "highBarBackSquat"):
                variant_reps = [r for r in squat_reps if r["variant"] == variant]
                if not variant_reps:
                    continue
                result = _derive_squat_form_audit(variant_reps, variant_filter=variant)
                if result:
                    _print_squat_report(result, variant)
                    print(_dart_squat_snippet(result, variant))
                    if not result.invariants_ok:
                        squat_any_failed = True
            if squat_any_failed:
                return 1
        if args.exercise == "squat":
            return 0

    # ── Curl analysis ───────────────────────────────────────────────────────
    if args.from_frames:
        sessions = _parse_frame_sessions(text)
        mode_label = "frame-signal (--from-frames)"
    else:
        sessions = _parse_sessions(text)
        mode_label = "rep.extremes"

    total_reps = sum(len(s.reps) for s in sessions)

    if total_reps == 0:
        if args.exercise == "all":
            return 0  # squat-only paste is fine when --exercise all
        if args.from_frames:
            print(
                "error: no reps detected from pose.frame_metrics angle_raw series.\n"
                "Check that:\n"
                "  1. kCurlDebugSessionEnabled = true\n"
                "  2. The log contains pose.frame_metrics lines\n"
                "  3. The user performed at least one full curl "
                f"(excursion >= {_FRAMES_MIN_EXCURSION}°)",
                file=sys.stderr,
            )
        else:
            print(
                "error: no rep.extremes lines found. Check that:\n"
                "  1. kCurlDebugSessionEnabled = true\n"
                "  2. The session ran to completion (reps were counted)\n"
                "  3. You used 'Copy all' (not 'Copy shown') in the Diagnostics screen\n"
                "\nTip: if the FSM thresholds are wrong and no reps counted, "
                "re-run with --from-frames to detect reps from the raw angle signal.",
                file=sys.stderr,
            )
        return 1

    _print_session_table(sessions)

    # Group sessions by (view, side) and derive per-group
    # If the user passed --view / --side, treat everything as one group
    if args.view or args.side:
        groups: dict[tuple[str, str], list[SessionBlock]] = {
            (args.view or "unknown", args.side or "unknown"): sessions
        }
    else:
        groups = {}
        for s in sessions:
            key = (s.view, s.side)
            groups.setdefault(key, []).append(s)

    any_failed = False
    any_derived = False
    for (view, side), group in sorted(groups.items()):
        results = _derive(group, args.view or (view if view != "unknown" else None),
                          args.side or (side if side != "unknown" else None))
        if results is None:
            reps_in_group = sum(len(s.reps) for s in group)
            print(
                f"\n⚠  ({view}, {side}): only {reps_in_group} reps — "
                f"need ≥{args.min_reps} to derive thresholds. Record more reps.",
                file=sys.stderr,
            )
            continue
        any_derived = True
        _print_report(results, args.verbose)
        if any(not r.invariants_ok for r in results):
            any_failed = True

    if not any_derived:
        print("\nerror: no group had enough reps to derive thresholds.", file=sys.stderr)
        return 1

    return 1 if any_failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
