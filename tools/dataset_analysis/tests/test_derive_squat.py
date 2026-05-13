"""Smoke test for ``scripts/derive_squat_thresholds_from_telemetry``.

Squat Pipeline Overhaul — Part 4.

Covers:
  * The telemetry parser ingests valid ``squat.rep`` lines and skips
    malformed / non-matching lines.
  * End-to-end derivation runs on a synthetic 20-rep fixture and emits a
    Dart ``SquatRomThresholdSet`` block that parses with stable angle
    values.
  * The FSM invariant (``startAngle > endAngle > bottomAngle``) holds on
    the synthetic data.
"""

from __future__ import annotations

import io
import re
import sys
from contextlib import redirect_stdout

import pytest

from scripts.derive_squat_thresholds_from_telemetry import (
    MIN_REPS_REQUIRED,
    derive_squat_rom,
    main,
    parse_squat_rep_lines,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _build_telemetry(
    n_reps: int = 20,
    variant: str = "bodyweight",
    min_knee_base: float = 82.0,
    max_knee_base: float = 172.0,
) -> str:
    """Build a synthetic telemetry log with ``n_reps`` squat.rep lines.

    Mirrors the line format emitted by `WorkoutViewModel._handleSquatRepCommit`.
    Angles vary slightly per rep so the Harrell-Davis percentile estimator
    sees realistic dispersion.
    """
    lines = [
        "[2026-05-13T08:00:00.000] squat_debug.session_start: ts=foo "
        "exercise=squat variant=bodyweight",
    ]
    for i in range(n_reps):
        # Vary min/max slightly to give MAD + HD non-trivial work.
        # Bottom deepens slightly for later reps; max stays in a band.
        min_knee = min_knee_base + (i % 5) * 0.4 - 1.0
        max_knee = max_knee_base + (i % 3) * 0.6 - 0.5
        lines.append(
            f"[2026-05-13T08:00:{i:02d}.000] squat.rep "
            f"rep={i + 1} variant={variant} long_femur=false "
            f"lean_deg=20.0 knee_shift=0.10 heel_lift=0.01 quality=0.92 "
            f"min_knee={min_knee:.2f} max_knee={max_knee:.2f}"
        )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Parser tests
# ---------------------------------------------------------------------------

def test_parse_squat_rep_lines_extracts_expected_reps():
    text = _build_telemetry(n_reps=20)
    reps = parse_squat_rep_lines(text)
    assert len(reps) == 20
    assert all(r.variant == "bodyweight" for r in reps)
    assert all(r.long_femur is False for r in reps)
    assert all(r.min_knee is not None for r in reps)
    assert all(r.max_knee is not None for r in reps)


def test_parse_squat_rep_lines_handles_null_min_max():
    # FSM may emit `min_knee=null max_knee=null` for analyzer-skipped reps
    # (pre-v9 reconstructed sessions, or reps where the knee wasn't measured
    # throughout the descent). The parser must accept those without crashing.
    text = (
        "squat_debug.session_start: ts=foo\n"
        "[t] squat.rep rep=1 variant=bodyweight long_femur=false "
        "lean_deg=20.0 knee_shift=0.10 heel_lift=0.01 quality=0.5 "
        "min_knee=null max_knee=null\n"
    )
    reps = parse_squat_rep_lines(text)
    assert len(reps) == 1
    assert reps[0].min_knee is None
    assert reps[0].max_knee is None


def test_parse_squat_rep_lines_returns_empty_for_unrelated_log():
    # Non-squat telemetry must not produce phantom reps.
    text = "[t] curl_debug.session_start: ts=foo\n[t] rep.extremes: ...\n"
    assert parse_squat_rep_lines(text) == []


# ---------------------------------------------------------------------------
# Derivation tests
# ---------------------------------------------------------------------------

def test_derive_returns_none_for_insufficient_reps():
    # 4 reps is below MIN_REPS_REQUIRED (5).
    text = _build_telemetry(n_reps=4)
    reps = parse_squat_rep_lines(text)
    assert derive_squat_rom(reps, variant="bodyweight") is None


def test_derive_returns_result_for_valid_fixture():
    text = _build_telemetry(n_reps=20)
    reps = parse_squat_rep_lines(text)
    d = derive_squat_rom(reps, variant="bodyweight")
    assert d is not None
    assert d.variant == "bodyweight"
    assert d.n_reps == 20
    # MAD rejection on tight synthetic data: most/all kept.
    assert d.n_kept_min >= MIN_REPS_REQUIRED
    assert d.n_kept_max >= MIN_REPS_REQUIRED


def test_derive_satisfies_fsm_invariant():
    text = _build_telemetry(n_reps=20)
    reps = parse_squat_rep_lines(text)
    d = derive_squat_rom(reps, variant="bodyweight")
    assert d is not None
    # CORE INVARIANT (also asserted in the Dart `SquatRomThresholdSet`
    # consumer): startAngle > endAngle > bottomAngle.
    assert d.start_angle > d.end_angle, (
        f"start={d.start_angle} end={d.end_angle}"
    )
    assert d.end_angle > d.bottom_angle, (
        f"end={d.end_angle} bottom={d.bottom_angle}"
    )
    assert d.invariants_ok
    assert d.violations == []


def test_derive_filters_to_specified_variant():
    # Mix two variants in one paste — `derive_squat_rom(reps, "bodyweight")`
    # must ignore HBBS reps and vice versa.
    bw = _build_telemetry(n_reps=10, variant="bodyweight")
    hbbs = _build_telemetry(
        n_reps=10,
        variant="highBarBackSquat",
        min_knee_base=75.0,  # deeper baseline
        max_knee_base=170.0,
    )
    combined_reps = parse_squat_rep_lines(bw + hbbs)
    bw_only = derive_squat_rom(combined_reps, variant="bodyweight")
    hbbs_only = derive_squat_rom(combined_reps, variant="highBarBackSquat")
    assert bw_only is not None and hbbs_only is not None
    # HBBS baseline was deeper (75 vs 82) — the derived bottomAngle should
    # reflect that. Pins variant filtering: if it were leaking the BW reps
    # into the HBBS derivation, the angles would converge.
    assert hbbs_only.bottom_angle < bw_only.bottom_angle


# ---------------------------------------------------------------------------
# End-to-end CLI test — runs `main()` with the fixture on stdin and parses
# the emitted Dart block.
# ---------------------------------------------------------------------------

_DART_BLOCK_RE = re.compile(
    r"static const SquatRomThresholdSet \w+Defaults\s*="
    r"\s*SquatRomThresholdSet\([^)]*"
    r"startAngle:\s*(?P<start>[\d.]+),\s*"
    r"bottomAngle:\s*(?P<bottom>[\d.]+),\s*"
    r"endAngle:\s*(?P<end>[\d.]+)",
    re.DOTALL,
)


def test_cli_emits_parseable_dart_block_with_valid_invariant(monkeypatch, tmp_path):
    text = _build_telemetry(n_reps=20)
    fixture = tmp_path / "session.txt"
    fixture.write_text(text)

    buf = io.StringIO()
    with redirect_stdout(buf):
        # Pass `--no-save` so the test doesn't write to the repo's
        # data/telemetry/derived/ directory.
        exit_code = main([str(fixture), "--no-save"])

    output = buf.getvalue()
    assert exit_code == 0, f"non-zero exit: {output}"

    m = _DART_BLOCK_RE.search(output)
    assert m is not None, f"Dart block not found in output:\n{output}"
    start = float(m.group("start"))
    bottom = float(m.group("bottom"))
    end = float(m.group("end"))
    # Echoes the in-process derivation invariant check — defends against a
    # regression where the formatter rounds inconsistently.
    assert start > end > bottom, f"invariant violated: {start}, {end}, {bottom}"


def test_cli_exits_nonzero_when_no_squat_reps(monkeypatch, tmp_path):
    fixture = tmp_path / "empty.txt"
    # Anything non-empty, but with no squat.rep lines.
    fixture.write_text("[t] curl_debug.session_start: ts=foo\n")
    # Capture stderr so the test doesn't pollute pytest output.
    buf_out = io.StringIO()
    buf_err = io.StringIO()
    monkeypatch.setattr(sys, "stderr", buf_err)
    with redirect_stdout(buf_out):
        exit_code = main([str(fixture), "--no-save"])
    assert exit_code == 1
    assert "no squat.rep" in buf_err.getvalue()
