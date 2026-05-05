"""Unit tests for scripts/generate_dart.py.

We assert on the shape and content of the emitted Dart source without
actually running the Dart compiler — string checks are enough here because
the template is static and simple.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts.generate_dart import (
    BANNER,
    build_parser,
    generate_dart,
    render_curl_block,
)


def _fake_payload() -> dict:
    """A plausible thresholds.json shape for deterministic rendering."""
    return {
        "curl": {
            "start_angle": {
                "value_deg": 155.7,
                "ci_low_deg": 152.3,
                "ci_high_deg": 158.9,
                "n": 20,
                "source_percentile": 20.0,
                "safety_margin_deg": 5.0,
            },
            "peak_angle": {
                "value_deg": 72.4,
                "ci_low_deg": 69.1,
                "ci_high_deg": 75.8,
                "n": 20,
                "source_percentile": 75.0,
                "safety_margin_deg": 5.0,
            },
            "peak_exit_angle": {
                "value_deg": 87.4,
                "ci_low_deg": 84.1,
                "ci_high_deg": 90.8,
                "n": 20,
                "source_percentile": 75.0,
                "safety_margin_deg": 5.0,
            },
            "end_angle": {
                "value_deg": 142.1,
                "ci_low_deg": 139.0,
                "ci_high_deg": 145.2,
                "n": 20,
                "source_percentile": 20.0,
                "safety_margin_deg": 5.0,
            },
            "peak_exit_gap_deg": 15.0,
        },
        "dataset_summary": {
            "total_rows": 30,
            "good_rows": 20,
            "clips": 2,
        },
    }


# ---------------------------------------------------------------------------
# render_curl_block
# ---------------------------------------------------------------------------


def test_render_curl_block_contains_do_not_edit_banner():
    out = render_curl_block(_fake_payload()["curl"], _fake_payload()["dataset_summary"])
    for line in BANNER.splitlines():
        assert line in out


def test_render_curl_block_emits_expected_constants():
    out = render_curl_block(_fake_payload()["curl"], _fake_payload()["dataset_summary"])
    assert "static const double curlStartAngle = 155.7;" in out
    assert "static const double curlPeakAngle = 72.4;" in out
    assert "static const double curlPeakExitAngle = 87.4;" in out
    assert "static const double curlEndAngle = 142.1;" in out
    assert "static const double curlPeakExitGap = 15.0;" in out


def test_render_curl_block_includes_dataset_provenance():
    out = render_curl_block(_fake_payload()["curl"], _fake_payload()["dataset_summary"])
    # "20 good reps / 30 total rows across 2 clip(s)"
    assert "20 good reps" in out
    assert "30 total rows" in out
    assert "2 clip" in out


def test_render_curl_block_includes_ci_docstrings():
    out = render_curl_block(_fake_payload()["curl"], _fake_payload()["dataset_summary"])
    # start CI formatted to 2 decimals
    assert "95% CI: [152.30, 158.90]" in out
    assert "95% CI: [69.10, 75.80]" in out


def test_render_curl_block_defines_class():
    out = render_curl_block(_fake_payload()["curl"], _fake_payload()["dataset_summary"])
    assert "class DefaultRomThresholds" in out
    assert "const DefaultRomThresholds._();" in out
    # library directive so this is a clean Dart library, not a mixed partial.
    assert "library;" in out


# ---------------------------------------------------------------------------
# generate_dart (full file IO)
# ---------------------------------------------------------------------------


def test_generate_dart_writes_file_with_expected_content(tmp_path: Path):
    thresholds_path = tmp_path / "thresholds.json"
    thresholds_path.write_text(json.dumps(_fake_payload()), encoding="utf-8")
    out_path = tmp_path / "default_rom_thresholds.dart"

    generate_dart(thresholds_path, out_path)

    content = out_path.read_text(encoding="utf-8")
    assert content.startswith("// GENERATED FILE")
    assert "class DefaultRomThresholds" in content
    assert "curlStartAngle = 155.7" in content


def test_generate_dart_raises_when_input_missing(tmp_path: Path):
    thresholds_path = tmp_path / "nope.json"  # not created
    out_path = tmp_path / "out.dart"
    with pytest.raises(FileNotFoundError):
        generate_dart(thresholds_path, out_path)


def test_generate_dart_raises_when_curl_section_missing(tmp_path: Path):
    thresholds_path = tmp_path / "thresholds.json"
    thresholds_path.write_text(json.dumps({"dataset_summary": {}}), encoding="utf-8")
    out_path = tmp_path / "out.dart"
    with pytest.raises(ValueError, match="missing required 'curl'"):
        generate_dart(thresholds_path, out_path)


def test_generate_dart_creates_parent_directory(tmp_path: Path):
    thresholds_path = tmp_path / "thresholds.json"
    thresholds_path.write_text(json.dumps(_fake_payload()), encoding="utf-8")
    out_path = tmp_path / "nested" / "dir" / "out.dart"
    generate_dart(thresholds_path, out_path)
    assert out_path.exists()


# ---------------------------------------------------------------------------
# build_parser
# ---------------------------------------------------------------------------


def test_parser_defaults_and_overrides():
    parser = build_parser()
    ns = parser.parse_args([])
    assert ns.thresholds.name == "thresholds.json"
    assert ns.out.name == "default_rom_thresholds.dart"

    ns2 = parser.parse_args(["--thresholds", "t.json", "--out", "/tmp/out.dart"])
    assert ns2.thresholds == Path("t.json")
    assert ns2.out == Path("/tmp/out.dart")
