"""Anchor functions for threshold derivation.

Two anchor strategies cover every gate the FSM and form audit care about:

  * ROM gates → bootstrapped median (`median_anchor`).
    The user's *typical* range. Tier tolerance is added on top to admit
    edge reps. Curl peak, curl start, push-up bottom, push-up start,
    push-up shallow, squat depth all use this anchor.

  * Fault upper bounds → Harrell-Davis P95 (`p95_anchor`).
    The user's *upper* tolerated range — 95 % of their reps are below this
    angle/ratio under good form. Tier tolerance lifts the warning gate a
    few degrees above the P95 so noise doesn't fire it. Squat lean,
    squat knee shift, squat heel lift use this anchor.

See `.agent_brain/SKILLS.md` → "Threshold Derivation Pipeline" (2026-05-14
PR B) for the full doctrine. Adding a new metric means writing one config
dict that names the metric, the anchor, the sign (+ or − for tolerance),
and the per-tier tolerance constants — the shared pipeline does the rest.
"""

from __future__ import annotations

from scripts.stats import bca_ci, hd_percentile


def median_anchor(values: list[float]) -> float:
    """Bootstrapped median for ROM gates.

    Uses BCa bootstrap on the Harrell-Davis P50 — lower variance than the
    order-statistic median at small n, matched to how
    `derive_thresholds_from_telemetry.py` historically computed `peak_point`
    for curl. Returns the point estimate only; callers that want the CI
    should call `stats.bca_ci` directly.
    """
    _, _, point = bca_ci(values, lambda vs: hd_percentile(vs, 50.0))
    return point


def p95_anchor(values: list[float]) -> float:
    """Harrell-Davis P95 for fault upper bounds.

    Not bootstrapped — `derive_thresholds_from_telemetry._derive_squat_form_audit`
    historically used `hd_percentile(lean_clean, 95.0)` directly, and the
    extraction preserves that choice. Bootstrapping would tighten the
    estimate at the cost of one second per call, which is not yet warranted
    for the squat sample sizes seen in production (≈30 reps/session).
    """
    return hd_percentile(values, 95.0)
