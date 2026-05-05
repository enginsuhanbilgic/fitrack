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
    Identical to Phase D-v2 (derive_thresholds_v2.py) where the sample
    size allows:
      * Per-rep extremes from ``rep.extremes`` lines OR frame-signal
        detection (``min=``, ``max=``, ``min_at_peak=`` — wrist-snap
        corrected peak; in frame mode peak = local min, start/end = local maxs)
      * MAD outlier rejection (threshold 2.5 × MAD — slightly tighter than
        the 3.5 used on large CSV datasets; small-session telemetry n is
        usually < 30, so aggressive rejection does more harm)
      * Harrell-Davis percentile estimator (P5 for peak, P95 for start/end)
      * BCa bootstrap CI (1 000 resamples — fewer than v2's 10 000 to keep
        CLI latency under 1 s at n ≈ 15)
      * Design-effect correction using session as cluster (ICC from
        one-way random-effects ANOVA)

GENERALIZATION TOLERANCES  (mirrors manual_rom_overrides.dart provenance)
    peak:       personal median + 28°   (covers users with ~40° peak ROM)
    start:      personal median − 8°    (covers users who only extend to ~145°)
    end:        start − 20°             (mirrors kProfileEndTolerance)
    peakExit:   peak + 15°              (mirrors kCurlPeakExitGap)

OUTPUT
    Terminal report + ready-to-paste Dart snippet for ManualRomOverrides.

USAGE
    # Default mode — requires reps to have been counted by the FSM:
    python -m scripts.derive_thresholds_from_telemetry telemetry.txt
    pbpaste | python -m scripts.derive_thresholds_from_telemetry

    # Frame-signal mode — works even when FSM never counted a rep:
    python -m scripts.derive_thresholds_from_telemetry --from-frames telemetry.txt
    python -m scripts.derive_thresholds_from_telemetry --from-frames --view sideLeft < log.txt

    # Override view/side labels (useful when session_start header is missing):
    python -m scripts.derive_thresholds_from_telemetry --view sideRight < log.txt
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Constants — must mirror app/lib/core/constants.dart
# ---------------------------------------------------------------------------

CURL_PEAK_EXIT_GAP_DEG = 15.0   # kCurlPeakExitGap
PROFILE_END_TOLERANCE = 20.0    # kProfileEndTolerance

# Generalization tolerances per sensitivity level.
# Keys must match CurlSensitivity.name values in types.dart.
# Values: peak_tolerance added to personal median peak (larger = looser gate);
#         start_tolerance subtracted from personal median start (larger = stricter start).
SENSITIVITIES: dict[str, dict[str, float]] = {
    "high":   {"peak_tolerance": 20.0, "start_tolerance": 5.0},
    "medium": {"peak_tolerance": 28.0, "start_tolerance": 8.0},
}
# Dart field name suffixes for each level (matches ManualRomOverrides convention).
_SENSITIVITY_SUFFIX: dict[str, str] = {
    "high":   "Strict",
    "medium": "Default",
}

# MAD outlier rejection threshold — matches derive_thresholds_v2.py.
# 2.5 was tried for small-n telemetry but caused over-rejection when peak angles
# cluster tightly (MAD < 1°), so a 3.5× cut removes reps that are within normal ROM.
MAD_REJECTION_THRESHOLD = 3.5

# Bootstrap
BOOTSTRAP_RESAMPLES = 1_000
BOOTSTRAP_SEED = 42

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
# Statistics (self-contained stdlib-only — no numpy/scipy dependency)
# ---------------------------------------------------------------------------


def _median(values: list[float]) -> float:
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def _mad(values: list[float]) -> float:
    """Median absolute deviation scaled by 1.4826 (normal-consistent σ estimator)."""
    med = _median(values)
    return 1.4826 * _median([abs(v - med) for v in values])


def mad_reject(values: list[float], threshold: float = MAD_REJECTION_THRESHOLD) -> list[float]:
    """Return values with outliers removed (> threshold × MAD from median)."""
    if len(values) < 4:
        return values[:]
    med = _median(values)
    mad = _mad(values)
    if mad == 0:
        return values[:]
    return [v for v in values if abs(v - med) / mad <= threshold]


# -- Regularised incomplete Beta via Lentz continued fractions ---------------

def _beta_cdf(x: float, a: float, b: float) -> float:
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    if x > (a + 1.0) / (a + b + 2.0):
        return 1.0 - _beta_cdf(1.0 - x, b, a)
    bt = math.exp(
        math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
        + a * math.log(x) + b * math.log(1.0 - x)
    )
    eps, fpmin = 3e-7, 1e-30
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    if abs(d) < fpmin:
        d = fpmin
    d = 1.0 / d
    h = d
    for m in range(1, 201):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return bt * h / a


def hd_percentile(values: list[float], q: float) -> float:
    """Harrell-Davis estimator of the q-th percentile (Harrell & Davis, 1982)."""
    s = sorted(values)
    n = len(s)
    if n == 1:
        return s[0]
    p = q / 100.0
    a_par = p * (n + 1)
    b_par = (1.0 - p) * (n + 1)
    total = 0.0
    prev = _beta_cdf(0.0, a_par, b_par)
    for i in range(1, n + 1):
        curr = _beta_cdf(i / n, a_par, b_par)
        total += (curr - prev) * s[i - 1]
        prev = curr
    return total


# -- BCa bootstrap CI --------------------------------------------------------

def _normal_cdf(z: float) -> float:
    return 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))


def _probit(p: float) -> float:
    """Beasley-Springer-Moro normal quantile — accurate to ~1e-9."""
    if p <= 0.0 or p >= 1.0:
        raise ValueError(f"probit out of range: {p}")
    a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
         1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
         6.680131188771972e+01, -1.328068155288572e+01]
    c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
         -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
         3.754408661907416e+00]
    p_low = 0.02425
    if p < p_low:
        q = math.sqrt(-2 * math.log(p))
        return ((((( c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / (((( d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    if p <= 1 - p_low:
        q = p - 0.5
        r = q * q
        return ((((( a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q / (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)
    q = math.sqrt(-2 * math.log(1 - p))
    return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)


def bca_ci(
    values: list[float],
    statistic,
    alpha: float = 0.05,
    n_boot: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float, float]:
    """Return (ci_low, ci_high, point_estimate) using BCa bootstrap."""
    import random
    rng = random.Random(seed)
    n = len(values)
    if n < 2:
        v = values[0] if values else 0.0
        return v, v, v

    theta_hat = statistic(values)

    boot = sorted(
        statistic([values[rng.randrange(n)] for _ in range(n)])
        for _ in range(n_boot)
    )

    n_below = sum(1 for s in boot if s < theta_hat)
    z0 = _probit(max(1, min(n_boot - 1, n_below)) / n_boot)

    jack = [statistic(values[:i] + values[i + 1:]) for i in range(n)]
    jmean = sum(jack) / n
    num = sum((jmean - j) ** 3 for j in jack)
    den = 6.0 * (sum((jmean - j) ** 2 for j in jack)) ** 1.5
    a_hat = num / den if den > 0 else 0.0

    z_lo, z_hi = _probit(alpha / 2), _probit(1 - alpha / 2)

    def adjusted(z: float) -> float:
        denom = 1.0 - a_hat * (z0 + z)
        if denom == 0:
            return 0.5
        return _normal_cdf(z0 + (z0 + z) / denom)

    al = max(0.0, min(1.0, adjusted(z_lo)))
    ah = max(0.0, min(1.0, adjusted(z_hi)))
    il = max(0, min(n_boot - 1, int(math.floor(al * n_boot))))
    ih = max(0, min(n_boot - 1, int(math.ceil(ah * n_boot)) - 1))
    return boot[il], boot[ih], theta_hat


# -- Design-effect (ICC) correction ------------------------------------------

def design_effect(
    values_by_session: dict[int, list[float]],
) -> tuple[float, float, int]:
    """Return (deff, icc, effective_n). Session is the cluster."""
    clusters = [v for v in values_by_session.values() if v]
    n_total = sum(len(c) for c in clusters)
    k = len(clusters)
    if k < 2 or n_total < 4:
        return 1.0, 0.0, n_total

    means = [sum(c) / len(c) for c in clusters]
    gm = sum(means) / k
    ss_b = sum(len(c) * (m - gm) ** 2 for c, m in zip(clusters, means))
    ss_w = sum(sum((v - m) ** 2 for v in c) for c, m in zip(clusters, means))
    df_b, df_w = k - 1, n_total - k
    if df_b <= 0 or df_w <= 0:
        return 1.0, 0.0, n_total
    ms_b, ms_w = ss_b / df_b, ss_w / df_w
    avg_m = n_total / k
    icc_d = ms_b + (avg_m - 1) * ms_w
    icc = max(0.0, (ms_b - ms_w) / icc_d) if icc_d > 0 else 0.0
    deff = 1.0 + (avg_m - 1) * icc
    return deff, icc, int(n_total / deff) if deff > 0 else n_total


# ---------------------------------------------------------------------------
# Threshold derivation
# ---------------------------------------------------------------------------

@dataclass
class DerivedThresholds:
    sensitivity: str   # "high" | "medium" | "low"
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

    # HD percentile estimators + BCa CI — computed once
    def stat_peak(vs: list[float]) -> float:
        return hd_percentile(vs, 5.0)

    def stat_start(vs: list[float]) -> float:
        return hd_percentile(vs, 95.0)

    peak_ci_lo, peak_ci_hi, peak_point = bca_ci(kept_peaks, stat_peak)
    start_ci_lo, start_ci_hi, start_point = bca_ci(kept_starts, stat_start)

    # Apply each sensitivity level's tolerances independently
    results: list[DerivedThresholds] = []
    for sens_name, tols in SENSITIVITIES.items():
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
            sensitivity=sens_name,
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
    """Emit three named constants (Strict / Default / Permissive) for one view."""
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
    print("  Personal medians (HD percentile before tolerances):")
    print(f"    peak   P5  = {first.median_peak_deg:>6.1f}°  "
          f"CI [{first.peak_ci[0]:.1f}°, {first.peak_ci[1]:.1f}°]")
    print(f"    start  P95 = {first.median_start_deg:>6.1f}°  "
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

# Tolerance added to P95 per sensitivity level.
# Looser than curl (squat biomechanics have wider inter-individual variation).
SQUAT_SENSITIVITIES: dict[str, dict[str, float]] = {
    "high":   {"lean_tol": 3.0,  "shift_tol": 0.03, "lift_tol": 0.005},
    "medium": {"lean_tol": 5.0,  "shift_tol": 0.05, "lift_tol": 0.008},
    "low":    {"lean_tol": 8.0,  "shift_tol": 0.08, "lift_tol": 0.012},
}
_SQUAT_SENSITIVITY_SUFFIX: dict[str, str] = {
    "high": "Strict", "medium": "Default", "low": "Permissive",
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

def _derive_squat(
    reps: list[dict],
    variant_filter: Optional[str] = None,
) -> Optional[list[DerivedSquatThresholds]]:
    """Derive squat thresholds for all 3 sensitivity levels.

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

    # MAD rejection (same 2.5× threshold as curl pipeline)
    lean_clean  = mad_reject(lean_vals)
    shift_clean = mad_reject(shift_vals)
    lift_clean  = mad_reject(lift_vals)

    # P95 Harrell-Davis — upper-bound metric; threshold covers 95% of population
    lean_p95  = hd_percentile(lean_clean,  0.95)
    shift_p95 = hd_percentile(shift_clean, 0.95)
    lift_p95  = hd_percentile(lift_clean,  0.95)

    results: list[DerivedSquatThresholds] = []
    for sens_name, tols in SQUAT_SENSITIVITIES.items():
        lean_thresh  = lean_p95  + tols["lean_tol"]
        shift_thresh = shift_p95 + tols["shift_tol"]
        lift_thresh  = lift_p95  + tols["lift_tol"]

        # No FSM ordering invariant for squat — thresholds are independent
        violations: list[str] = []
        if lean_thresh <= 0:
            violations.append("lean_thresh must be > 0")
        if shift_thresh <= 0:
            violations.append("shift_thresh must be > 0")
        if lift_thresh <= 0:
            violations.append("lift_thresh must be > 0")

        results.append(DerivedSquatThresholds(
            sensitivity=sens_name,
            variant=variant_filter or "all",
            lean_warn_deg=round(lean_thresh, 1),
            knee_shift_warn=round(shift_thresh, 4),
            heel_lift_warn=round(lift_thresh, 4),
            lean_n=len(lean_clean),
            shift_n=len(shift_clean),
            lift_n=len(lift_clean),
            invariants_ok=len(violations) == 0,
            violations=violations,
        ))
    return results


# ---------------------------------------------------------------------------
# Squat output helpers
# ---------------------------------------------------------------------------

def _dart_squat_snippet(results: list[DerivedSquatThresholds], variant: str) -> str:
    lines = [f"// Squat thresholds derived from telemetry — variant: {variant}"]
    for r in results:
        suffix = _SQUAT_SENSITIVITY_SUFFIX[r.sensitivity]
        comment = "// DEFAULT — replaces constants.dart value" if r.sensitivity == "medium" else ""
        lines += [
            "",
            f"// {r.sensitivity.upper()} sensitivity (n={r.lean_n} reps)",
            f"const double kSquatLeanWarnDeg{variant.title().replace('_','')}{'Strict' if suffix == 'Strict' else '' if suffix == 'Default' else 'Permissive'} = {r.lean_warn_deg}; {comment}",
            f"const double kSquatKneeShiftWarnRatio{'Strict' if suffix == 'Strict' else '' if suffix == 'Default' else 'Permissive'} = {r.knee_shift_warn};",
            f"const double kSquatHeelLiftWarnRatio{'Strict' if suffix == 'Strict' else '' if suffix == 'Default' else 'Permissive'} = {r.heel_lift_warn};",
        ]
    return "\n".join(lines)


def _print_squat_report(results: list[DerivedSquatThresholds], variant: str) -> None:
    print(f"\n{'─'*60}")
    print(f"  Squat thresholds — {variant}")
    print(f"{'─'*60}")
    header = f"{'Sensitivity':<12} {'Lean (°)':<12} {'Knee shift':<14} {'Heel lift':<12} N"
    print(header)
    print("─" * len(header))
    for r in results:
        flag = "" if r.invariants_ok else " ⚠ VIOLATION"
        print(
            f"{r.sensitivity:<12} "
            f"{r.lean_warn_deg:<12.1f} "
            f"{r.knee_shift_warn:<14.4f} "
            f"{r.heel_lift_warn:<12.4f} "
            f"{r.lean_n}{flag}"
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
                results = _derive_squat(variant_reps, variant_filter=variant)
                if results:
                    _print_squat_report(results, variant)
                    print(_dart_squat_snippet(results, variant))
                    if any(not r.invariants_ok for r in results):
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
