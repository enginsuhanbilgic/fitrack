import 'dart:math' as math;

import '../../core/constants.dart';
import '../../models/landmark_types.dart';
import '../../models/pose_result.dart';
import '../one_euro_filter.dart';

/// Direction classification emitted by [SagittalSwayDetector.update].
enum SagittalSwayDirection { neutral, forward, backward }

/// Result of a single detector update — direction plus the underlying signal
/// values (exposed for telemetry / quality scoring, not for FSM gating).
class SagittalSwayResult {
  const SagittalSwayResult({
    required this.direction,
    required this.compositeZ,
    required this.velocityPerSec,
    required this.baselineReady,
  });

  /// Final classified direction after hysteresis.
  final SagittalSwayDirection direction;

  /// Z-scored composite `S(t)` (sigma-units relative to baseline).
  /// `null` until the baseline window is full.
  final double? compositeZ;

  /// Time-normalized velocity `v(t) = ΔS / Δt` in sigma-units per second.
  /// `null` until at least one prior `S(t)` exists.
  final double? velocityPerSec;

  /// True once the baseline window has been collected and z-scoring +
  /// classification are active. False during warm-up.
  final bool baselineReady;
}

/// Front-view sagittal (toward/away-from-camera) torso sway detector.
///
/// ML Kit's 2D pose has no usable depth channel. Sagittal motion projects
/// almost entirely onto the camera's optical axis, so naive 2D X/Y deltas
/// miss it. Under a pinhole projection model, however, the apparent size
/// of an in-plane body span scales as 1/Z (linear) or 1/Z² (area) — so a
/// shrinking torso is the user moving away, a growing torso is the user
/// moving in.
///
/// The detector builds three scale-invariant features:
///   - `f₁ = d_s / d_h`            (shoulder/hip width ratio)
///   - `f₂ = A   / d_h²`           (torso area / hip width²)
///   - `f₃ = L   / d_s`            (torso vertical / shoulder width)
///
/// All three are dimensionless and cancel global scale (camera distance,
/// person size). Each is 1€-filtered to attenuate landmark jitter while
/// preserving fast lifting motion (project gotcha: 1€ is mandatory for
/// landmark smoothing — EMA was rejected). After a baseline window of
/// neutral-pose frames, each feature is z-scored against `(μᵢ, σᵢ)` and
/// summed with calibrated weights into a composite `S(t)`. Classification
/// runs on the **time-normalized velocity** `v(t) = (S(t) − S(t−Δt)) / Δt`
/// (Δt from frame timestamps) so the same threshold works at 30 fps and
/// 60 fps — a hard requirement for the cross-platform non-regression rule.
///
/// A frame is rejected when:
///   - any of the four torso landmarks is below
///     [kSagittalMinLandmarkVisibility]; or
///   - `Δt` since the last accepted frame exceeds
///     [kSagittalDtAnomalyFactor] × the rolling median (thermal-throttle
///     guards).
///
/// After the baseline window closes, σ continues to adapt slowly but is
/// hard-capped at [kSagittalSigmaDriftCap] × the initial baseline σ so
/// fatigue-induced sway over a long set doesn't get absorbed into the
/// "neutral" range.
class SagittalSwayDetector {
  // ── Filters (one per feature) ───────────────────────────
  final OneEuroFilter _f1Filter = OneEuroFilter();
  final OneEuroFilter _f2Filter = OneEuroFilter();
  final OneEuroFilter _f3Filter = OneEuroFilter();

  // ── Baseline accumulators ───────────────────────────────
  final List<double> _baselineF1 = [];
  final List<double> _baselineF2 = [];
  final List<double> _baselineF3 = [];

  double _muF1 = 0, _muF2 = 0, _muF3 = 0;
  double _sigF1 = 1, _sigF2 = 1, _sigF3 = 1;
  double _initialSigF1 = 1, _initialSigF2 = 1, _initialSigF3 = 1;
  bool _baselineReady = false;

  // ── Composite + velocity state ──────────────────────────
  double? _prevS;
  double? _prevT;

  // Rolling dt window for anomaly rejection.
  final List<double> _dtWindow = [];
  static const int _dtWindowSize = 10;

  // Hysteresis state.
  int _consecutiveForward = 0;
  int _consecutiveBackward = 0;
  SagittalSwayDirection _lastDirection = SagittalSwayDirection.neutral;

  /// Reset all state — call on view change, session reset, or whenever a
  /// new baseline must be collected. Filters are reset, baseline window
  /// re-opens, hysteresis cleared.
  void reset() {
    _f1Filter.reset();
    _f2Filter.reset();
    _f3Filter.reset();
    _baselineF1.clear();
    _baselineF2.clear();
    _baselineF3.clear();
    _muF1 = 0;
    _muF2 = 0;
    _muF3 = 0;
    _sigF1 = 1;
    _sigF2 = 1;
    _sigF3 = 1;
    _initialSigF1 = 1;
    _initialSigF2 = 1;
    _initialSigF3 = 1;
    _baselineReady = false;
    _prevS = null;
    _prevT = null;
    _dtWindow.clear();
    _consecutiveForward = 0;
    _consecutiveBackward = 0;
    _lastDirection = SagittalSwayDirection.neutral;
  }

  /// True once the baseline window has filled and z-scoring is active.
  bool get baselineReady => _baselineReady;

  /// Ingest a frame and return the current sway result.
  ///
  /// [now] is the wall-clock instant of this pose sample (use
  /// `DateTime.now()` at the analyzer call-site, matching the convention
  /// used by `CurlFormAnalyzer` for tempo timing). [allowBaseline] is true
  /// when the host knows the user is in a neutral-pose state (FSM IDLE or
  /// near-full elbow extension) — only baseline-eligible frames feed
  /// `(μ, σ)`. Non-baseline frames still update the running signal once
  /// the baseline is ready, so reps don't blank the detector.
  SagittalSwayResult update({
    required PoseResult pose,
    required DateTime now,
    required bool allowBaseline,
  }) {
    final features = _computeFeatures(pose);
    if (features == null) {
      // Visibility / geometry gate failed — surface the prior direction
      // (no flip) but do not advance baseline or velocity state.
      return SagittalSwayResult(
        direction: _lastDirection,
        compositeZ: null,
        velocityPerSec: null,
        baselineReady: _baselineReady,
      );
    }

    final t = now.microsecondsSinceEpoch / 1e6;

    // 1€-filter each feature.
    final f1 = _f1Filter.filter(features.f1, t);
    final f2 = _f2Filter.filter(features.f2, t);
    final f3 = _f3Filter.filter(features.f3, t);

    // Baseline collection — only when the host says the pose is neutral.
    if (allowBaseline && !_baselineReady) {
      _baselineF1.add(f1);
      _baselineF2.add(f2);
      _baselineF3.add(f3);
      if (_baselineF1.length >= kSagittalBaselineMinFrames) {
        _muF1 = _mean(_baselineF1);
        _muF2 = _mean(_baselineF2);
        _muF3 = _mean(_baselineF3);
        _sigF1 = _stddev(_baselineF1, _muF1);
        _sigF2 = _stddev(_baselineF2, _muF2);
        _sigF3 = _stddev(_baselineF3, _muF3);
        _initialSigF1 = _sigF1;
        _initialSigF2 = _sigF2;
        _initialSigF3 = _sigF3;
        _baselineReady = true;
        // Seed `_prevS` / `_prevT` from the closing baseline frame so the
        // very next call can compute a velocity (otherwise we'd waste 1–2
        // post-baseline frames re-establishing the previous-sample state).
        _prevS = 0.0; // by construction this frame is at the baseline mean
        _prevT = t;
      }
      return SagittalSwayResult(
        direction: SagittalSwayDirection.neutral,
        compositeZ: null,
        velocityPerSec: null,
        baselineReady: _baselineReady,
      );
    }

    if (!_baselineReady) {
      // Baseline still warming, host marked frame ineligible — wait.
      return SagittalSwayResult(
        direction: SagittalSwayDirection.neutral,
        compositeZ: null,
        velocityPerSec: null,
        baselineReady: false,
      );
    }

    // Slow σ adaptation (only on baseline-eligible frames after warm-up)
    // with hard cap to prevent drift swallowing real form breakdown.
    if (allowBaseline) {
      _adaptSigma(f1, f2, f3);
    }

    // Z-score each feature.
    final z1 = (f1 - _muF1) / (_sigF1 + 1e-6);
    final z2 = (f2 - _muF2) / (_sigF2 + 1e-6);
    final z3 = (f3 - _muF3) / (_sigF3 + 1e-6);

    final s =
        kSagittalWeightShoulderHipRatio * z1 +
        kSagittalWeightTorsoArea * z2 +
        kSagittalWeightTorsoLengthRatio * z3;

    // Velocity with frame-rate normalization + dt anomaly guard.
    double? v;
    if (_prevS != null && _prevT != null) {
      final dt = t - _prevT!;
      if (dt > 0) {
        if (_dtWindow.isNotEmpty) {
          final medianDt = _median(_dtWindow);
          if (dt > medianDt * kSagittalDtAnomalyFactor) {
            // Frame skip — keep prevS/prevT stale, suppress this v(t).
            return SagittalSwayResult(
              direction: _lastDirection,
              compositeZ: s,
              velocityPerSec: null,
              baselineReady: true,
            );
          }
        }
        v = (s - _prevS!) / dt;
        _pushDt(dt);
      }
    }
    _prevS = s;
    _prevT = t;

    if (v == null) {
      return SagittalSwayResult(
        direction: _lastDirection,
        compositeZ: s,
        velocityPerSec: null,
        baselineReady: true,
      );
    }

    // Hysteresis classification.
    if (v > kSagittalVelocityThreshold) {
      _consecutiveForward++;
      _consecutiveBackward = 0;
      if (_consecutiveForward >= kSagittalHysteresisFrames) {
        _lastDirection = SagittalSwayDirection.forward;
      }
    } else if (v < -kSagittalVelocityThreshold) {
      _consecutiveBackward++;
      _consecutiveForward = 0;
      if (_consecutiveBackward >= kSagittalHysteresisFrames) {
        _lastDirection = SagittalSwayDirection.backward;
      }
    } else {
      _consecutiveForward = 0;
      _consecutiveBackward = 0;
      _lastDirection = SagittalSwayDirection.neutral;
    }

    return SagittalSwayResult(
      direction: _lastDirection,
      compositeZ: s,
      velocityPerSec: v,
      baselineReady: true,
    );
  }

  // ── Internals ───────────────────────────────────────────

  /// Compute the three scale-invariant features from a pose. Returns null
  /// when any required landmark is missing or below the visibility gate
  /// or when the geometry is degenerate (zero hip width, etc.).
  _Features? _computeFeatures(PoseResult pose) {
    final ls = pose.landmark(
      LM.leftShoulder,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final rs = pose.landmark(
      LM.rightShoulder,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final lh = pose.landmark(
      LM.leftHip,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    final rh = pose.landmark(
      LM.rightHip,
      minConfidence: kSagittalMinLandmarkVisibility,
    );
    if (ls == null || rs == null || lh == null || rh == null) return null;

    // 1) Shoulder-aligned frame: Center at shoulders, rotate to horizontal.
    final scx = (ls.x + rs.x) / 2;
    final scy = (ls.y + rs.y) / 2;
    final theta = math.atan2(rs.y - ls.y, rs.x - ls.x);
    final cosT = math.cos(-theta);
    final sinT = math.sin(-theta);

    _Pt rotate(double x, double y) {
      final dx = x - scx;
      final dy = y - scy;
      return _Pt(dx * cosT - dy * sinT, dx * sinT + dy * cosT);
    }

    final lsPrime = rotate(ls.x, ls.y);
    final rsPrime = rotate(rs.x, rs.y);
    final lhPrime = rotate(lh.x, lh.y);
    final rhPrime = rotate(rh.x, rh.y);

    // 2) Stabilized torso axis and bottom edge.
    final hcx = (lhPrime.x + rhPrime.x) / 2;
    final hcy = (lhPrime.y + rhPrime.y) / 2;
    final hlen = math.sqrt(hcx * hcx + hcy * hcy);
    if (hlen < 1e-4) return null;

    final ux = hcx / hlen; // Torso axis unit vector
    final uy = hcy / hlen;
    final vx = -uy; // Perpendicular unit vector (bottom edge)
    final vy = ux;

    // Project hips onto the synthetic bottom line through Hc.
    double project(_Pt p) => (p.x - hcx) * vx + (p.y - hcy) * vy;
    final dL = project(lhPrime);
    final dR = project(rhPrime);

    final lhStabilized = _Pt(hcx + dL * vx, hcy + dL * vy);
    final rhStabilized = _Pt(hcx + dR * vx, hcy + dR * vy);

    // 3) Shoulder-priority features.
    final ds = (rsPrime.x - lsPrime.x).abs();
    final dh = _dist(
      lhStabilized.x,
      lhStabilized.y,
      rhStabilized.x,
      rhStabilized.y,
    );
    if (ds < 1e-4 || dh < 1e-4) return null;

    // Stabilized area of the (Sl, Sr, Hr, Hl) quad.
    final area =
        0.5 *
        ((lsPrime.x * rsPrime.y - rsPrime.x * lsPrime.y) +
                (rsPrime.x * rhStabilized.y - rhStabilized.x * rsPrime.y) +
                (rhStabilized.x * lhStabilized.y - lhStabilized.x * rhStabilized.y) +
                (lhStabilized.x * lsPrime.y - lsPrime.x * lhStabilized.y))
            .abs();

    return _Features(f1: ds / dh, f2: area / (dh * dh), f3: hlen / ds);
  }

  void _adaptSigma(double f1, double f2, double f3) {
    // EMA-style σ tracking, then hard cap. Slow α (~0.02) so a single
    // off-frame can't expand the band materially.
    const alpha = 0.02;
    _sigF1 = (1 - alpha) * _sigF1 + alpha * (f1 - _muF1).abs();
    _sigF2 = (1 - alpha) * _sigF2 + alpha * (f2 - _muF2).abs();
    _sigF3 = (1 - alpha) * _sigF3 + alpha * (f3 - _muF3).abs();
    if (_sigF1 > kSagittalSigmaDriftCap * _initialSigF1) {
      _sigF1 = kSagittalSigmaDriftCap * _initialSigF1;
    }
    if (_sigF2 > kSagittalSigmaDriftCap * _initialSigF2) {
      _sigF2 = kSagittalSigmaDriftCap * _initialSigF2;
    }
    if (_sigF3 > kSagittalSigmaDriftCap * _initialSigF3) {
      _sigF3 = kSagittalSigmaDriftCap * _initialSigF3;
    }
  }

  void _pushDt(double dt) {
    _dtWindow.add(dt);
    if (_dtWindow.length > _dtWindowSize) {
      _dtWindow.removeAt(0);
    }
  }

  static double _dist(double ax, double ay, double bx, double by) {
    final dx = ax - bx;
    final dy = ay - by;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _mean(List<double> xs) =>
      xs.fold(0.0, (a, b) => a + b) / xs.length;

  static double _stddev(List<double> xs, double mu) {
    if (xs.length < 2) return 1e-3;
    final v = xs.fold(0.0, (a, x) => a + (x - mu) * (x - mu)) / (xs.length - 1);
    final s = math.sqrt(v);
    // Floor σ so a perfectly still baseline doesn't divide by ~0.
    return s < 1e-3 ? 1e-3 : s;
  }

  static double _median(List<double> xs) {
    final sorted = List<double>.from(xs)..sort();
    final n = sorted.length;
    if (n.isOdd) return sorted[n ~/ 2];
    return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
  }
}

class _Features {
  const _Features({required this.f1, required this.f2, required this.f3});
  final double f1;
  final double f2;
  final double f3;
}

class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}
