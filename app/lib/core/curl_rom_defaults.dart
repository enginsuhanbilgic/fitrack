/// Per-view ROM threshold defaults for the **biceps-curl FSM**.
///
/// One of three per-exercise `*_rom_defaults.dart` files. File naming follows
/// the exercise; provenance (telemetry vs literature vs other) is documented
/// in the doc-block below per the 2026-05-13 project convention.
///
/// PROVENANCE — telemetry-derived (PROJECT CONVENTION)
/// ────────────────────────────────────────────────────
/// All constants below come from live in-app diagnostic-session telemetry
/// (the "Curl debug session" Settings toggle) — NOT from an offline
/// video-clip analysis pipeline. Workflow when retuning:
///   1. Record a diagnostic session, paste the log to
///      `tools/dataset_analysis/data/telemetry/sessions/`.
///   2. Run `derive_thresholds_from_telemetry.py` — it auto-saves the
///      derived report to `data/telemetry/derived/`.
///   3. Paste the Dart snippet block from the derived report over the
///      matching `static const` block(s) below.
///
/// Highest-precedence layer in the three-tier resolver:
///   1. Telemetry-derived defaults (this file)         ← project convention
///   2. Pipeline-derived defaults  (`pipeline_rom_defaults.dart`, shelved)
///   3. Legacy hand-tuned constants (`constants.dart`)
///
/// Gated by [kUseTelemetryRomDefaults] in `constants.dart`. When the flag is on,
/// `RomThresholds.global(view)` consults [forView] first; if the view has an
/// entry, it wins. Views with `null` entries fall through to whichever of the
/// two lower tiers is active.
///
/// SENSITIVITY CONTRACT (2026-05-14)
/// ─────────────────────────────────
/// [forView] returns the **High-anchored** tuple unconditionally. The caller
/// (`RomThresholds.global`) applies telemetry-specific looseness deltas via
/// `_applyTelemetrySensitivity` to derive Medium. The legacy
/// `sideLeft/RightDefault` tuples have been removed — Medium numbers are
/// reproduced bit-for-bit by applying `(-3, +8, +8)` to the anchor tuple.
///
/// PROVENANCE — sideLeft / sideRight buckets
/// ─────────────────────────────────────────
/// Source: diagnostic session 2026-04-28, left-arm side view, --from-frames
/// mode (FSM thresholds were misconfigured so no rep.extremes were emitted;
/// reps were detected from raw angle_raw signal via local-min/max detector).
/// n=7 raw reps, 5 kept after 3.5×MAD rejection. Personal medians: peak=108.4°,
/// start=167.0°. Permissive level omitted — geometrically invalid for this
/// user's ROM (peakExit would exceed startAngle with +38° tolerance).
library;

import 'pipeline_rom_defaults.dart';
import 'types.dart';

class CurlRomDefaults {
  const CurlRomDefaults._();

  // Front-view defaults removed 2026-05 along with the front analyzer.
  // The `CurlCameraView.front` enum value is retained as a view-detector
  // fallback sentinel; the `forView` resolver returns null for it so
  // callers cascade to the next ROM tier.

  // ── Side-left anchor (derived 2026-04-28, --from-frames mode) ────────────
  // Source: diagnostic session 2026-04-28 (left-arm, side view).
  // 7 reps detected via local-min/max frame-signal detector; 5 kept after
  // 3.5×MAD outlier rejection. Personal medians: peak=108.4°, start=167.0°.
  // ICC=0.000 (single session), eff_n=5. Mirror-inverted session logged as
  // sideRight due to a known home-screen mapping bug — angles are identical
  // by bilateral symmetry so these constants apply to both views.
  //
  // Values represent the **High anchor**. Medium is derived by applying the
  // telemetry-specific looseness deltas (-3, +8, +8) inside
  // `RomThresholds._applyTelemetrySensitivity`.

  static const CurlRomThresholdSet sideLeftAnchor = CurlRomThresholdSet(
    startAngle: 162.0,
    peakAngle: 128.4,
    peakExitAngle: 143.4,
    endAngle: 148.4,
  );

  // ── Side-right anchor (aliases sideLeft — bilateral symmetry) ──────────
  // Elbow-angle geometry is identical across left/right in the 2D sagittal
  // projection. True Dart const alias — changing sideLeftAnchor above
  // automatically propagates here with no manual sync needed.
  static const CurlRomThresholdSet sideRightAnchor = sideLeftAnchor;

  /// Look up the telemetry-derived **High-anchored** tuple for a given view.
  ///
  /// Returns null when no anchor is defined for that view — caller falls
  /// through to the next resolution tier.
  ///
  /// Sensitivity is no longer a parameter — the caller applies it via the
  /// telemetry-specific post-pass on `RomThresholds`. See file-level
  /// "SENSITIVITY CONTRACT" doc-block.
  static CurlRomThresholdSet? forView(CurlCameraView view) {
    switch (view) {
      case CurlCameraView.front:
        // Front view removed 2026-05; sentinel only. Cascade to the next
        // ROM tier by returning null.
        return null;
      case CurlCameraView.sideLeft:
        return sideLeftAnchor;
      case CurlCameraView.sideRight:
        return sideRightAnchor;
      case CurlCameraView.unknown:
        return null;
    }
  }
}
