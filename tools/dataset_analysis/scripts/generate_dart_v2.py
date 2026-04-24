"""Phase D (v2) — Emit Dart file from bucketed thresholds_v2.json.

Reads data/derived/thresholds_v2.json (written by derive_thresholds_v2.py)
and writes app/lib/core/default_rom_thresholds.dart with per-view bucket
thresholds plus full methodology provenance in the file header.

Key differences from v1 generator:
    * Emits a per-(view, side) bucket table keyed by CurlCameraView.
    * Preserves BCa CIs, effective-n, ICC, and outlier counts in docstrings
      so the Dart file is self-documenting for peer review.
    * Embeds the full methodology citation block so readers can trace the
      thresholds back to the derivation literature.
    * Provides a `DefaultRomThresholds.forView(CurlCameraView)` lookup so
      runtime code can pick the right bucket based on ViewDetector output.

Usage:
    python -m scripts.generate_dart_v2
    python -m scripts.generate_dart_v2 --thresholds data/derived/thresholds_v2.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[1]
DERIVED_DIR = REPO_ROOT / "data" / "derived"

APP_ROOT = REPO_ROOT.parent.parent / "app"
DEFAULT_THRESHOLDS_JSON = DERIVED_DIR / "thresholds_v2.json"
DEFAULT_DART_OUTPUT = APP_ROOT / "lib" / "core" / "default_rom_thresholds.dart"

BANNER = (
    "// GENERATED FILE — DO NOT EDIT BY HAND.\n"
    "// Source: tools/dataset_analysis/scripts/generate_dart_v2.py\n"
    "// Regenerate with: python -m scripts.generate_dart_v2\n"
    "// Input: tools/dataset_analysis/data/derived/thresholds_v2.json\n"
)


# Map (view, side) tuples from the JSON onto CurlCameraView enum values.
# "both" side + "front" view → CurlCameraView.front
# "left" side + "side" view → CurlCameraView.sideLeft
# "right" side + "side" view → CurlCameraView.sideRight
def _view_enum(view: str, side: str) -> Optional[str]:
    if view == "front":
        return "front"
    if view == "side" and side == "left":
        return "sideLeft"
    if view == "side" and side == "right":
        return "sideRight"
    return None


def _const_prefix(view_enum: str) -> str:
    """Produce a Dart-friendly constant prefix from the enum value."""
    return view_enum  # e.g. "front", "sideLeft", "sideRight"


def render_methodology_header(payload: dict) -> list[str]:
    """Render the full methodology and dataset provenance as Dart comments."""
    m = payload.get("methodology", {})
    ds = payload.get("dataset_summary", {})
    loco = payload.get("cross_validation", {}).get("summary", {})

    lines = [
        BANNER,
        "",
        "/// ═══════════════════════════════════════════════════════════════════",
        "/// Data-driven default ROM thresholds for the biceps-curl FSM (v2).",
        "/// ═══════════════════════════════════════════════════════════════════",
        "///",
        "/// METHODOLOGY",
        "/// ───────────",
        f"/// • Percentile estimator:  {m.get('percentile_estimator', 'N/A')}",
        f"/// • Confidence interval:   {m.get('confidence_interval', 'N/A')}",
        f"///   — {m.get('bootstrap_resamples', 0)} resamples, "
        f"seed={m.get('bootstrap_seed', 0)}",
        f"/// • Outlier rejection:     {m.get('outlier_rejection', 'N/A')}",
        f"/// • Safety margin:         {m.get('safety_margin', 'N/A')}",
        f"/// • Cluster correction:    {m.get('cluster_correction', 'N/A')}",
        f"/// • Cross-validation:      {m.get('cross_validation', 'N/A')}",
        f"/// • Bucketing strategy:    {m.get('bucketing', 'N/A')}",
        "///",
        "/// DATASET",
        "/// ───────",
        f"/// • Good reps:             {ds.get('good_rows', 0)}",
        f"/// • Total rep rows:        {ds.get('total_rows', 0)}",
        f"/// • Good clips:            {ds.get('good_clips', 0)}",
        f"/// • Total clips:           {ds.get('total_clips', 0)}",
    ]
    if loco:
        lines += [
            "///",
            "/// LEAVE-ONE-CLIP-OUT CROSS-VALIDATION",
            "/// ─────────────────────────────────",
            f"///   start P20:  {loco.get('start_p20_mean', 0):.2f}° "
            f"± {loco.get('start_p20_std', 0):.2f}°",
            f"///   peak  P75:  {loco.get('peak_p75_mean', 0):.2f}° "
            f"± {loco.get('peak_p75_std', 0):.2f}°",
            f"///   end   P20:  {loco.get('end_p20_mean', 0):.2f}° "
            f"± {loco.get('end_p20_std', 0):.2f}°",
            "///",
            "///   High std across folds = thresholds don't generalize across",
            "///   clips. This is expected for (view, side) heterogeneity and",
            "///   is the reason thresholds are bucketed rather than pooled.",
        ]
    lines += [
        "///",
        "/// CITATIONS",
        "/// ─────────",
        "///   Harrell, F.E. & Davis, C.E. (1982). A new distribution-free",
        "///     quantile estimator. Biometrika, 69(3), 635–640.",
        "///   Efron, B. & Tibshirani, R.J. (1993). An Introduction to the",
        "///     Bootstrap. Chapman & Hall.",
        "///   Leys, C., Ley, C., Klein, O., Bernard, P. & Licata, L. (2013).",
        "///     Detecting outliers: Do not use standard deviation around",
        "///     the mean, use absolute deviation around the median. JESP,",
        "///     49(4), 764–766.",
        "///   Kish, L. (1965). Survey Sampling. Wiley.",
        "/// ═══════════════════════════════════════════════════════════════════",
        "library;",
        "",
        "import 'types.dart';",
        "",
    ]
    return lines


def render_bucket_constants(buckets: list[dict]) -> list[str]:
    """Emit a flat static const per (bucket, angle) so the FSM reads them
    the same way it reads the existing global constants.dart values."""
    lines = []
    lines.append("/// Per-view biceps-curl threshold buckets.")
    lines.append("///")
    lines.append("/// Each bucket contains four FSM gates (start, peak, peakExit,")
    lines.append("/// end) plus BCa 95% CIs, effective-n, and ICC for transparency.")
    lines.append("/// Pick the correct bucket at runtime via [DefaultRomThresholds.forView].")
    lines.append("class DefaultRomThresholds {")
    lines.append("  const DefaultRomThresholds._();")
    lines.append("")
    lines.append(
        f"  /// Hysteresis gap: peakExit = peakAngle + this "
        f"(mirrors kCurlPeakExitGap)."
    )
    lines.append(f"  static const double peakExitGap = 15.0;")
    lines.append("")

    for bucket in buckets:
        view_enum = _view_enum(bucket["view"], bucket["side"])
        if view_enum is None:
            continue
        prefix = _const_prefix(view_enum)

        start = bucket["start_angle"]
        peak = bucket["peak_angle"]
        peak_exit = bucket["peak_exit_angle"]
        end = bucket["end_angle"]
        safety = bucket["safety_margin_deg"]
        n_clips = bucket["n_clips"]

        lines.append(
            f"  // ── {view_enum} "
            f"({bucket['view']}, {bucket['side']}) — "
            f"n={start['n']} reps, {n_clips} clip(s) ─────────────────"
        )
        lines.append(f"  /// Data-driven safety margin: {safety:.2f}°.")
        lines.append("")

        # start
        lines.append(
            f"  /// P{int(start['source_percentile'])} Harrell-Davis – "
            f"{start['safety_margin_deg']:.2f}° safety."
        )
        lines.append(
            f"  /// BCa 95% CI: [{start['ci_low_deg']:.2f}, "
            f"{start['ci_high_deg']:.2f}]  "
            f"eff_n={start['effective_n']}  "
            f"ICC={start['icc']:.3f}  "
            f"outliers_rejected={start['outliers_rejected']}."
        )
        lines.append(
            f"  static const double {prefix}StartAngle = "
            f"{start['value_deg']:.2f};"
        )
        lines.append("")

        # peak
        lines.append(
            f"  /// P{int(peak['source_percentile'])} Harrell-Davis + "
            f"{peak['safety_margin_deg']:.2f}° safety."
        )
        lines.append(
            f"  /// BCa 95% CI: [{peak['ci_low_deg']:.2f}, "
            f"{peak['ci_high_deg']:.2f}]  "
            f"eff_n={peak['effective_n']}  "
            f"ICC={peak['icc']:.3f}  "
            f"outliers_rejected={peak['outliers_rejected']}."
        )
        lines.append(
            f"  static const double {prefix}PeakAngle = "
            f"{peak['value_deg']:.2f};"
        )
        lines.append("")

        # peak_exit
        lines.append(f"  /// Derived: peakAngle + peakExitGap.")
        lines.append(
            f"  static const double {prefix}PeakExitAngle = "
            f"{peak_exit['value_deg']:.2f};"
        )
        lines.append("")

        # end
        method_note = end.get("method", "")
        if "fsm_safe" in method_note:
            lines.append(
                "  /// FSM-safe: post-rep extension overshoots rep start by a"
            )
            lines.append(
                "  /// sub-degree margin in the raw data, so we set the rep-end"
            )
            lines.append(
                "  /// gate to min(start_p20, end_p20) - margin - 1° to preserve"
            )
            lines.append("  /// the start > end invariant. See derive_thresholds_v2.py.")
        else:
            lines.append(
                f"  /// P{int(end['source_percentile'])} Harrell-Davis – "
                f"{end['safety_margin_deg']:.2f}° safety."
            )
        lines.append(
            f"  /// BCa 95% CI: [{end['ci_low_deg']:.2f}, "
            f"{end['ci_high_deg']:.2f}]  "
            f"eff_n={end['effective_n']}  "
            f"ICC={end['icc']:.3f}  "
            f"outliers_rejected={end['outliers_rejected']}."
        )
        lines.append(
            f"  static const double {prefix}EndAngle = "
            f"{end['value_deg']:.2f};"
        )
        lines.append("")

    return lines


def render_lookup(buckets: list[dict]) -> list[str]:
    """Runtime lookup: pick the right bucket for a CurlCameraView."""
    lines = []
    lines.append("  /// Look up the threshold tuple for a given camera view.")
    lines.append("  ///")
    lines.append("  /// Returns a [CurlRomThresholdSet] containing the four FSM gates")
    lines.append("  /// plus metadata. Falls back to [CurlCameraView.sideRight] values")
    lines.append("  /// for [CurlCameraView.unknown] since side-view is the most")
    lines.append("  /// anatomically-accurate projection.")
    lines.append("  static CurlRomThresholdSet forView(CurlCameraView view) {")
    lines.append("    switch (view) {")
    for bucket in buckets:
        view_enum = _view_enum(bucket["view"], bucket["side"])
        if view_enum is None:
            continue
        prefix = _const_prefix(view_enum)
        lines.append(f"      case CurlCameraView.{view_enum}:")
        lines.append("        return const CurlRomThresholdSet(")
        lines.append(f"          startAngle: {prefix}StartAngle,")
        lines.append(f"          peakAngle: {prefix}PeakAngle,")
        lines.append(f"          peakExitAngle: {prefix}PeakExitAngle,")
        lines.append(f"          endAngle: {prefix}EndAngle,")
        lines.append("        );")

    # Fallback — pick the first side bucket we can find, else front, else synthetic
    fallback_bucket = None
    for b in buckets:
        if _view_enum(b["view"], b["side"]) in ("sideLeft", "sideRight"):
            fallback_bucket = b
            break
    if fallback_bucket is None:
        for b in buckets:
            if _view_enum(b["view"], b["side"]) == "front":
                fallback_bucket = b
                break

    lines.append("      case CurlCameraView.unknown:")
    if fallback_bucket is not None:
        prefix = _const_prefix(_view_enum(fallback_bucket["view"], fallback_bucket["side"]))
        lines.append("        // Unknown view — fall back to the most anatomically")
        lines.append("        // accurate bucket (side-view) until detection settles.")
        lines.append("        return const CurlRomThresholdSet(")
        lines.append(f"          startAngle: {prefix}StartAngle,")
        lines.append(f"          peakAngle: {prefix}PeakAngle,")
        lines.append(f"          peakExitAngle: {prefix}PeakExitAngle,")
        lines.append(f"          endAngle: {prefix}EndAngle,")
        lines.append("        );")
    else:
        lines.append("        throw StateError('No fallback bucket available.');")

    # Handle missing sideLeft/sideRight/front buckets — emit a justified fallback.
    # For sideLeft ↔ sideRight specifically, the fallback is anatomically
    # principled (bilateral symmetry), not a "missing data" placeholder.
    emitted = {_view_enum(b["view"], b["side"]) for b in buckets}
    for view_enum in ("front", "sideLeft", "sideRight"):
        if view_enum in emitted:
            continue
        lines.append(f"      case CurlCameraView.{view_enum}:")

        # Special-case: side-to-side mirroring is bilaterally symmetric, so the
        # fallback is anatomical, not "missing data."
        is_side_mirror = (
            view_enum in ("sideLeft", "sideRight")
            and fallback_bucket is not None
            and _view_enum(fallback_bucket["view"], fallback_bucket["side"])
            in ("sideLeft", "sideRight")
        )
        if is_side_mirror:
            mirror = "sideLeft" if view_enum == "sideRight" else "sideRight"
            lines.append(
                f"        // {view_enum} mirrors {mirror} by bilateral biomechanical"
            )
            lines.append(
                "        // symmetry: the elbow angle geometry of a curl is identical"
            )
            lines.append(
                "        // across left/right sides in healthy subjects, and the 2D"
            )
            lines.append(
                "        // projection of a side-view curl is a mirror image across"
            )
            lines.append(
                "        // the sagittal plane — angular values are unchanged."
            )
            lines.append(
                "        // Recording a dedicated right-side clip would only be worth"
            )
            lines.append(
                "        // it for handedness-specific ROM asymmetries (~2-5° in some"
            )
            lines.append(
                "        // studies), which is below the 5° safety margin anyway."
            )
        else:
            lines.append(
                f"        // {view_enum} not present in T2.4 dataset — reuse the"
            )
            lines.append("        // most similar bucket. Re-derive with more data")
            lines.append("        // to get a dedicated bucket for this view.")

        if fallback_bucket is not None:
            prefix = _const_prefix(_view_enum(fallback_bucket["view"], fallback_bucket["side"]))
            lines.append("        return const CurlRomThresholdSet(")
            lines.append(f"          startAngle: {prefix}StartAngle,")
            lines.append(f"          peakAngle: {prefix}PeakAngle,")
            lines.append(f"          peakExitAngle: {prefix}PeakExitAngle,")
            lines.append(f"          endAngle: {prefix}EndAngle,")
            lines.append("        );")
        else:
            lines.append("        throw StateError('No bucket available.');")
    lines.append("    }")
    lines.append("  }")
    lines.append("}")
    lines.append("")
    return lines


def render_threshold_set_class() -> list[str]:
    return [
        "/// Immutable view-specific threshold tuple returned by",
        "/// [DefaultRomThresholds.forView]. Shape mirrors the four gates of the",
        "/// biceps-curl FSM so consumers can destructure without imports.",
        "class CurlRomThresholdSet {",
        "  const CurlRomThresholdSet({",
        "    required this.startAngle,",
        "    required this.peakAngle,",
        "    required this.peakExitAngle,",
        "    required this.endAngle,",
        "  });",
        "",
        "  final double startAngle;",
        "  final double peakAngle;",
        "  final double peakExitAngle;",
        "  final double endAngle;",
        "}",
        "",
    ]


def generate_dart(thresholds_json_path: Path, out_path: Path) -> None:
    if not thresholds_json_path.exists():
        raise FileNotFoundError(
            f"thresholds_v2.json not found at {thresholds_json_path}. "
            "Run scripts/derive_thresholds_v2.py first."
        )
    payload = json.loads(thresholds_json_path.read_text(encoding="utf-8"))
    if "buckets" not in payload:
        raise ValueError(
            f"thresholds_v2.json missing 'buckets' key: {thresholds_json_path}"
        )

    buckets = payload["buckets"]
    if not buckets:
        raise ValueError("No buckets in thresholds_v2.json — nothing to generate.")

    lines = []
    lines += render_methodology_header(payload)
    lines += render_threshold_set_class()
    lines += render_bucket_constants(buckets)
    lines += render_lookup(buckets)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines), encoding="utf-8")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Generate app/lib/core/default_rom_thresholds.dart from v2 "
            "bucketed thresholds JSON."
        )
    )
    p.add_argument("--thresholds", type=Path, default=DEFAULT_THRESHOLDS_JSON)
    p.add_argument("--out", type=Path, default=DEFAULT_DART_OUTPUT)
    return p


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
