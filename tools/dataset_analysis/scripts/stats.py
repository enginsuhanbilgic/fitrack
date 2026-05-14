"""Statistical helpers shared by all telemetry-derivation scripts.

Houses the helpers that previously lived inside
`derive_thresholds_from_telemetry.py`. Lifting them out lets `anchors.py`
depend on them (anchors are bootstrapped statistics) without dragging in the
curl-specific derivation surface — which would create a circular import the
moment a third script (push-up) tried to share the math.

Single source of truth: a fix to the BCa numerics, the Harrell-Davis
estimator, or the MAD outlier rule lands here and every derivation script
sees it on the next invocation.

The bodies are moved verbatim from the curl derivation script; the curl
script now re-imports them. Push-up script likewise. Behavior is preserved
bit-for-bit — anyone with a pre-extraction terminal log can diff against a
post-extraction run.
"""

from __future__ import annotations

import math
import random
from typing import Callable

# 2.5 was tried for small-n telemetry but caused over-rejection when peak
# angles cluster tightly (MAD < 1°), so a 3.5× cut removes reps that are
# within normal ROM. Shared across curl, squat, push-up derivations — every
# script applied the same constant pre-extraction.
MAD_REJECTION_THRESHOLD = 3.5

# Bootstrap config — shared across exercises. Resamples=1000 / seed=42 is
# the historical curl-script choice; the same numbers shipped on the
# push-up derivation pre-extraction.
BOOTSTRAP_RESAMPLES = 1_000
BOOTSTRAP_SEED = 42


# -- Median + MAD -------------------------------------------------------------

def _median(values: list[float]) -> float:
    s = sorted(values)
    n = len(s)
    mid = n // 2
    return s[mid] if n % 2 == 1 else (s[mid - 1] + s[mid]) / 2.0


def _mad(values: list[float]) -> float:
    """Median absolute deviation scaled by 1.4826 (normal-consistent σ estimator)."""
    med = _median(values)
    return 1.4826 * _median([abs(v - med) for v in values])


def mad_reject(
    values: list[float],
    threshold: float = MAD_REJECTION_THRESHOLD,
) -> list[float]:
    """Return values with outliers removed (> threshold × MAD from median).

    Returns a copy of the input for n<4 (too thin to estimate MAD reliably)
    or MAD==0 (a degenerate tightly-clustered sample where everything is an
    outlier under a relative rule). Both fallbacks preserve the input — the
    rep counter cares about *removing* outliers, not about whether the
    statistic is defined.
    """
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
    """Harrell-Davis estimator of the q-th percentile (Harrell & Davis, 1982).

    `q` is in percent (0..100) — `hd_percentile(xs, 50)` returns the median,
    `hd_percentile(xs, 95)` returns the P95. Lower variance than the order
    statistic at small n; preferred over numpy.percentile for FiTrack's
    typical 5–20 reps-per-session telemetry. Returns the single value for
    n==1 inputs without crashing.
    """
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
    statistic: Callable[[list[float]], float],
    alpha: float = 0.05,
    n_boot: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float, float]:
    """Return (ci_low, ci_high, point_estimate) using BCa bootstrap.

    Seeded RNG so the same input + statistic produces the same numbers across
    runs — important for the derivation scripts' golden-output discipline.
    """
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
    """Return (deff, icc, effective_n). Session is the cluster.

    Used by every script's per-(view,side) or per-tier derivation step to
    shrink the effective n when reps within a session are correlated.
    Body moved verbatim from `derive_thresholds_from_telemetry.py`; the
    formula uses the average cluster size (n_total / k) rather than the
    Snijders & Bosker harmonic-mean correction — preserved bit-for-bit so
    any pre-extraction derivation result reproduces post-extraction.
    """
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
