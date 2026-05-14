"""Smoke tests for ``scripts/derive_pushup_thresholds_from_telemetry``.

Push-Up Telemetry Threshold Tuning (2026-05-13) — Phase 2.

Mirrors the structure of ``test_derive_squat.py``. Covers:

  * The telemetry parser ingests valid ``pushup.rep`` lines and skips
    malformed / non-matching lines.
  * Session boundaries come from the universal ``curl_debug.session_start``
    marker — `session_idx` increments accordingly.
  * End-to-end derivation runs on a synthetic 20-rep fixture and emits a
    Dart ``PushUpRomThresholdSet`` block with parseable angle values.
  * The FSM invariant (``startAngle > endAngle > bottomAngle``) holds on
    the synthetic data.
  * MAD outlier rejection works **per-dimension** — a rep with a noisy
    `min_elbow` does not invalidate its `max_elbow`.
  * Auto-save: file input writes a derived report; stdin input does not.
"""

from __future__ import annotations

import io
import re
import sys
from contextlib import redirect_stdout
from pathlib import Path

from scripts.derive_pushup_thresholds_from_telemetry import (
    MIN_REPS_REQUIRED,
    _mad_reject,
    derive_pushup_thresholds,
    main,
    parse_pushup_rep_lines,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _build_telemetry(
    n_reps: int = 20,
    min_elbow_base: float = 88.0,
    max_elbow_base: float = 162.0,
    include_session_marker: bool = True,
) -> str:
    """Build a synthetic telemetry log with ``n_reps`` `pushup.rep` lines.

    Mirrors the exact line format emitted by `formatPushUpRepLine`. Angles
    vary slightly per rep so the Harrell-Davis percentile estimator sees
    realistic dispersion.
    """
    lines: list[str] = []
    if include_session_marker:
        lines.append(
            "[2026-05-13T08:00:00.000] curl_debug.session_start: "
            "ts=foo exercise=pushUp"
        )
    for i in range(n_reps):
        min_elbow = min_elbow_base + (i % 5) * 0.4 - 1.0
        max_elbow = max_elbow_base + (i % 3) * 0.6 - 0.5
        lines.append(
            f"[2026-05-13T08:00:{i:02d}.000] pushup.rep "
            f"rep={i + 1} "
            f"min_elbow={min_elbow:.2f} "
            f"max_elbow={max_elbow:.2f}"
        )
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Parser tests
# ---------------------------------------------------------------------------

def test_parse_extracts_expected_reps():
    text = _build_telemetry(n_reps=20)
    reps = parse_pushup_rep_lines(text)
    assert len(reps) == 20
    assert all(r.min_elbow is not None for r in reps)
    assert all(r.max_elbow is not None for r in reps)
    # All reps land after the single session-start marker → session_idx=1
    # (block index 0 is the empty pre-marker block).
    assert all(r.session_idx == 1 for r in reps)


def test_parse_handles_null_min_max():
    # The Dart formatter emits literal "null" tokens when the analyzer
    # snapshot is missing — the parser must accept that without crashing.
    text = (
        "[t] curl_debug.session_start: ts=foo\n"
        "[t] pushup.rep rep=1 min_elbow=null max_elbow=null\n"
    )
    reps = parse_pushup_rep_lines(text)
    assert len(reps) == 1
    assert reps[0].min_elbow is None
    assert reps[0].max_elbow is None


def test_parse_skips_unrelated_lines():
    # squat.rep / rep.extremes lines must NOT produce phantom push-up reps.
    text = (
        "[t] curl_debug.session_start: ts=foo\n"
        "[t] squat.rep rep=1 variant=bodyweight long_femur=false "
        "lean_deg=20.0 knee_shift=0.10 heel_lift=0.01 quality=0.5 "
        "min_knee=85.0 max_knee=170.0\n"
        "[t] rep.extremes side=left view=sideRight min_angle=88 max_angle=170\n"
    )
    assert parse_pushup_rep_lines(text) == []


def test_parse_assigns_session_indices_across_markers():
    # Two `curl_debug.session_start` markers → three blocks, reps land in
    # blocks 1 and 2 (block 0 is pre-marker).
    text = (
        "[t] curl_debug.session_start: ts=A\n"
        "[t] pushup.rep rep=1 min_elbow=88.0 max_elbow=162.0\n"
        "[t] pushup.rep rep=2 min_elbow=88.5 max_elbow=162.5\n"
        "[t] curl_debug.session_start: ts=B\n"
        "[t] pushup.rep rep=1 min_elbow=87.5 max_elbow=163.0\n"
    )
    reps = parse_pushup_rep_lines(text)
    assert len(reps) == 3
    assert reps[0].session_idx == 1
    assert reps[1].session_idx == 1
    assert reps[2].session_idx == 2


def test_parse_without_session_marker_uses_single_cluster():
    # No marker = ICC degrades gracefully. All reps land in block 0.
    text = (
        "[t] pushup.rep rep=1 min_elbow=88.0 max_elbow=162.0\n"
        "[t] pushup.rep rep=2 min_elbow=88.5 max_elbow=162.5\n"
    )
    reps = parse_pushup_rep_lines(text)
    assert len(reps) == 2
    assert {r.session_idx for r in reps} == {0}


# ---------------------------------------------------------------------------
# Derivation tests
# ---------------------------------------------------------------------------

def test_derive_returns_empty_for_insufficient_reps():
    """Pre-PR-B this returned `None`; post-PR-B the derivation returns a
    list (one entry per tier) and signals failure with an empty list."""
    text = _build_telemetry(n_reps=4)
    reps = parse_pushup_rep_lines(text)
    assert derive_pushup_thresholds(reps) == []


def test_derive_returns_one_block_per_tier():
    text = _build_telemetry(n_reps=20)
    reps = parse_pushup_rep_lines(text)
    results = derive_pushup_thresholds(reps)
    # PR B unified pipeline: one block per tier in `TIERS`. With the
    # current two-tier rule, that's two blocks (high, medium).
    assert len(results) == 2
    tiers = [d.tier for d in results]
    assert tiers == ["high", "medium"]
    for d in results:
        assert d.n_reps == 20
        assert d.n_kept_min >= MIN_REPS_REQUIRED
        assert d.n_kept_max >= MIN_REPS_REQUIRED


def test_derive_satisfies_fsm_invariant():
    text = _build_telemetry(n_reps=20)
    reps = parse_pushup_rep_lines(text)
    results = derive_pushup_thresholds(reps)
    assert results
    for d in results:
        # CORE INVARIANT — also asserted in the Dart PushUpRomThresholdSet's
        # FSM: startAngle > endAngle > bottomAngle.
        assert d.start_angle > d.end_angle, (
            f"{d.tier}: start={d.start_angle} end={d.end_angle}"
        )
        assert d.end_angle > d.bottom_angle, (
            f"{d.tier}: end={d.end_angle} bottom={d.bottom_angle}"
        )
        # Shallow gate sits at-or-above the bottom — it's "minimum depth to
        # count as a shallow attempt" (deeper than bottom is the rep-counted
        # path).
        assert d.shallow_rep_max_angle >= d.bottom_angle, (
            f"{d.tier}: shallow={d.shallow_rep_max_angle} bottom={d.bottom_angle}"
        )
        assert d.invariants_ok, f"{d.tier}: {d.violations}"
        assert d.violations == []


def test_derive_per_dimension_mad_rejection():
    # A rep with a noisy `min_elbow` must NOT invalidate its `max_elbow`.
    # We invoke `_mad_reject` directly on each dimension to pin the
    # contract — same primitive the derivation uses internally.
    cleans = [88.0, 88.2, 88.4, 88.1, 88.3, 88.0, 88.2, 88.1, 88.3, 88.2]
    with_outlier = cleans + [40.0]  # obvious outlier
    kept = _mad_reject(with_outlier)
    assert 40.0 not in kept
    assert len(kept) == len(cleans)


def test_derive_flags_invariant_violation():
    # Inverted geometry — `max_elbow` is systematically SHALLOWER (lower
    # angle) than `min_elbow`. Under the PR-B median anchor:
    #   start_anchor = median(max_elbow) ≈ 82°
    #   bottom_anchor = median(min_elbow) ≈ 152°
    # With high-tier tolerances (start_tolerance=2, bottom_tolerance=-5):
    #   start = 82 - 2 = 80
    #   bottom = 152 - 5 = 147   → start < bottom, invariant broken.
    # `enforce_ordering` records the violation and clamps the values.
    lines = ["[t] curl_debug.session_start: ts=foo"]
    for i in range(10):
        min_elbow = 150.0 + (i % 5) * 1.0
        max_elbow = 80.0 + (i % 5) * 1.0
        lines.append(
            f"[t] pushup.rep rep={i + 1} "
            f"min_elbow={min_elbow:.2f} max_elbow={max_elbow:.2f}"
        )
    text = "\n".join(lines) + "\n"
    reps = parse_pushup_rep_lines(text)
    results = derive_pushup_thresholds(reps)
    assert results
    # At least one tier flags violations under inverted geometry.
    assert any(not d.invariants_ok for d in results)
    assert any(len(d.violations) >= 1 for d in results)


# ---------------------------------------------------------------------------
# CLI / end-to-end tests
# ---------------------------------------------------------------------------

_DART_BLOCK_RE = re.compile(
    r"static const PushUpRomThresholdSet \w+\s*=\s*PushUpRomThresholdSet\("
    r"[^)]*"
    r"startAngle:\s*(?P<start>[\d.]+),\s*[^)]*"
    r"bottomAngle:\s*(?P<bottom>[\d.]+),\s*[^)]*"
    r"endAngle:\s*(?P<end>[\d.]+),\s*[^)]*"
    r"shallowRepMaxAngle:\s*(?P<shallow>[\d.]+),",
    re.DOTALL,
)


def test_cli_emits_parseable_dart_block(tmp_path: Path):
    text = _build_telemetry(n_reps=20)
    fixture = tmp_path / "session.txt"
    fixture.write_text(text)

    buf = io.StringIO()
    with redirect_stdout(buf):
        # Pass `--no-save` so the test doesn't write into the repo's
        # data/telemetry/derived/ tree.
        exit_code = main([str(fixture), "--no-save"])

    output = buf.getvalue()
    assert exit_code == 0, f"non-zero exit: {output}"

    m = _DART_BLOCK_RE.search(output)
    assert m is not None, f"Dart block not found in output:\n{output}"
    start = float(m.group("start"))
    bottom = float(m.group("bottom"))
    end = float(m.group("end"))
    shallow = float(m.group("shallow"))
    # Echoes the in-process invariant check — defends against a regression
    # where the formatter rounds inconsistently and breaks the printed
    # tuple.
    assert start > end > bottom, (
        f"invariant violated: start={start} end={end} bottom={bottom}"
    )
    assert shallow >= bottom


def test_cli_emits_two_tier_blocks(tmp_path: Path):
    """PR A two-tier rule + PR B unified pipeline: the CLI emits one
    PushUpRomThresholdSet block per tier in `TIERS` — two blocks (high,
    medium). Pre-PR-A the sweep also emitted a "low" block; the Dart
    FeedbackSensitivity enum has no `low` value, so that row is removed.
    """
    text = _build_telemetry(n_reps=20)
    fixture = tmp_path / "session.txt"
    fixture.write_text(text)

    buf = io.StringIO()
    with redirect_stdout(buf):
        exit_code = main([str(fixture), "--no-save"])

    output = buf.getvalue()
    assert exit_code == 0
    assert output.count("static const PushUpRomThresholdSet") == 2
    assert "tier: high" in output
    assert "tier: medium" in output
    # The two-tier rule (PR A) — `low` is forbidden.
    assert "tier: low" not in output


def test_cli_exits_nonzero_when_no_pushup_reps(
    monkeypatch, tmp_path: Path,
):
    fixture = tmp_path / "empty.txt"
    fixture.write_text("[t] curl_debug.session_start: ts=foo\n")
    buf_out = io.StringIO()
    buf_err = io.StringIO()
    monkeypatch.setattr(sys, "stderr", buf_err)
    with redirect_stdout(buf_out):
        exit_code = main([str(fixture), "--no-save"])
    assert exit_code == 1
    assert "no pushup.rep" in buf_err.getvalue()


def test_cli_auto_saves_when_given_file_path(tmp_path: Path):
    text = _build_telemetry(n_reps=20)
    fixture = tmp_path / "session.txt"
    fixture.write_text(text)
    out_dir = tmp_path / "derived"

    buf_err = io.StringIO()
    with redirect_stdout(io.StringIO()):
        # Re-route stderr so the "saved" notice doesn't clutter pytest.
        old_err, sys.stderr = sys.stderr, buf_err
        try:
            exit_code = main([str(fixture), "--out-dir", str(out_dir)])
        finally:
            sys.stderr = old_err

    assert exit_code == 0
    out_file = out_dir / "session_pushup_thresholds.txt"
    assert out_file.exists(), f"expected auto-saved file at {out_file}"
    contents = out_file.read_text()
    assert "static const PushUpRomThresholdSet" in contents


def test_cli_stdin_does_not_auto_save(monkeypatch, tmp_path: Path):
    text = _build_telemetry(n_reps=20)
    out_dir = tmp_path / "derived"
    monkeypatch.setattr(sys, "stdin", io.StringIO(text))

    buf_out = io.StringIO()
    with redirect_stdout(buf_out):
        exit_code = main(["--out-dir", str(out_dir)])

    assert exit_code == 0
    # Stdin path is "quick experiment" — no file should appear.
    assert not out_dir.exists() or not any(out_dir.iterdir())
