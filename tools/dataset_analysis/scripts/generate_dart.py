"""Phase D — Emit Dart file from derived thresholds JSON.

Reads data/derived/thresholds.json (written by derive_thresholds.py) and
writes app/lib/core/default_rom_thresholds.dart. Generated file is:

    * prefixed with a DO NOT EDIT banner pointing at this script
    * includes dataset provenance (N good reps, clip count) as comments
    * exposes a `DefaultRomThresholds` class (curl-only initially) with
      `startAngle`, `peakAngle`, `peakExitAngle`, `endAngle`, `peakExitGap`

The Dart class is deliberately POD — just double constants — so runtime code
that currently reads `kCurlStartAngle` etc. can migrate incrementally.

Usage:
    python scripts/generate_dart.py
    python scripts/generate_dart.py --thresholds data/derived/thresholds.json \\
                                    --out ../../app/lib/core/default_rom_thresholds.dart
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
DERIVED_DIR = REPO_ROOT / "data" / "derived"

# From tools/dataset_analysis/ up one to repo root, then into app/lib/core/.
APP_ROOT = REPO_ROOT.parent.parent / "app"
DEFAULT_THRESHOLDS_JSON = DERIVED_DIR / "thresholds.json"
DEFAULT_DART_OUTPUT = APP_ROOT / "lib" / "core" / "default_rom_thresholds.dart"

BANNER = (
    "// GENERATED FILE — DO NOT EDIT BY HAND.\n"
    "// Source: tools/dataset_analysis/scripts/generate_dart.py\n"
    "// Regenerate with: python tools/dataset_analysis/scripts/generate_dart.py\n"
    "// Input: tools/dataset_analysis/data/derived/thresholds.json\n"
)


def render_curl_block(curl: dict, dataset_summary: dict) -> str:
    """Render the single `curl` section into a Dart class body.

    We format every derived number to one decimal place — enough precision for
    a threshold gate, readable in a diff, and consistent with how the existing
    kCurlStartAngle etc. are written in constants.dart.
    """
    good = dataset_summary.get("good_rows", 0)
    total = dataset_summary.get("total_rows", 0)
    clips = dataset_summary.get("clips", 0)

    start = curl["start_angle"]
    peak = curl["peak_angle"]
    peak_exit = curl["peak_exit_angle"]
    end = curl["end_angle"]
    peak_exit_gap = curl["peak_exit_gap_deg"]

    lines: list[str] = []
    lines.append(BANNER)
    lines.append("")
    lines.append("/// Data-driven default ROM thresholds for the biceps curl FSM.")
    lines.append("///")
    lines.append("/// Derived from tools/dataset_analysis/data/derived/thresholds.json.")
    lines.append(f"/// Dataset: {good} good reps / {total} total rows across {clips} clip(s).")
    lines.append("///")
    lines.append("/// The shipping FSM reads these as defaults; per-user ROM profiles can")
    lines.append("/// still tighten the gates via kProfile* tolerances in constants.dart.")
    lines.append("library;")
    lines.append("")
    lines.append("class DefaultRomThresholds {")
    lines.append("  const DefaultRomThresholds._();")
    lines.append("")
    lines.append("  // ── Biceps curl ──────────────────────────────────────────")
    lines.append(
        f"  /// Derived at P{int(start['source_percentile'])} "
        f"- {start['safety_margin_deg']}° safety margin. "
        f"95% CI: [{start['ci_low_deg']:.2f}, {start['ci_high_deg']:.2f}]."
    )
    lines.append(f"  static const double curlStartAngle = {start['value_deg']:.1f};")
    lines.append("")
    lines.append(
        f"  /// Derived at P{int(peak['source_percentile'])} "
        f"+ {peak['safety_margin_deg']}° safety margin. "
        f"95% CI: [{peak['ci_low_deg']:.2f}, {peak['ci_high_deg']:.2f}]."
    )
    lines.append(f"  static const double curlPeakAngle = {peak['value_deg']:.1f};")
    lines.append("")
    lines.append(
        f"  /// Derived as curlPeakAngle + kCurlPeakExitGap ({peak_exit_gap}°)."
    )
    lines.append(f"  static const double curlPeakExitAngle = {peak_exit['value_deg']:.1f};")
    lines.append("")
    lines.append(
        f"  /// Derived at P{int(end['source_percentile'])} "
        f"- {end['safety_margin_deg']}° safety margin. "
        f"95% CI: [{end['ci_low_deg']:.2f}, {end['ci_high_deg']:.2f}]."
    )
    lines.append(f"  static const double curlEndAngle = {end['value_deg']:.1f};")
    lines.append("")
    lines.append(f"  /// Hysteresis gap (peakExit = peak + this).")
    lines.append(f"  static const double curlPeakExitGap = {peak_exit_gap:.1f};")
    lines.append("}")
    lines.append("")

    return "\n".join(lines)


def generate_dart(thresholds_json_path: Path, out_path: Path) -> None:
    if not thresholds_json_path.exists():
        raise FileNotFoundError(
            f"thresholds.json not found at {thresholds_json_path}. "
            "Run scripts/derive_thresholds.py first."
        )
    payload = json.loads(thresholds_json_path.read_text(encoding="utf-8"))
    if "curl" not in payload:
        raise ValueError(
            f"thresholds.json missing required 'curl' key: {thresholds_json_path}"
        )

    rendered = render_curl_block(payload["curl"], payload.get("dataset_summary", {}))
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(rendered, encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Generate app/lib/core/default_rom_thresholds.dart from the "
            "derived thresholds JSON."
        )
    )
    parser.add_argument(
        "--thresholds",
        type=Path,
        default=DEFAULT_THRESHOLDS_JSON,
        help="Path to thresholds.json (from derive_thresholds.py).",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_DART_OUTPUT,
        help="Destination Dart file. Defaults to app/lib/core/default_rom_thresholds.dart.",
    )
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        generate_dart(args.thresholds, args.out)
    except (FileNotFoundError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"Wrote {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


__all__ = [
    "BANNER",
    "DEFAULT_DART_OUTPUT",
    "DEFAULT_THRESHOLDS_JSON",
    "build_parser",
    "generate_dart",
    "main",
    "render_curl_block",
]
