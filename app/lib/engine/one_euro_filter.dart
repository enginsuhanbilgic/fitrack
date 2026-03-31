import 'dart:math';
import '../core/constants.dart';

/// 1€ Filter — speed-adaptive low-pass filter for noisy landmark data.
/// Reference: Casiez et al., CHI 2012.
/// https://gery.casiez.net/1euro/
class OneEuroFilter {
  final double _minCutoff;
  final double _beta;
  final double _dCutoff;

  double? _xPrev;
  double? _dxPrev;
  double? _tPrev;

  OneEuroFilter({
    double minCutoff = kOneEuroMinCutoff,
    double beta = kOneEuroBeta,
    double dCutoff = kOneEuroDCutoff,
  })  : _minCutoff = minCutoff,
        _beta = beta,
        _dCutoff = dCutoff;

  double filter(double x, double t) {
    if (_tPrev == null) {
      _xPrev = x;
      _dxPrev = 0;
      _tPrev = t;
      return x;
    }

    final double dt = t - _tPrev!;
    if (dt <= 0) return _xPrev!;

    // Derivative (speed).
    final double dx = (x - _xPrev!) / dt;
    final double alphaDx = _alpha(dt, _dCutoff);
    final double dxHat = alphaDx * dx + (1 - alphaDx) * _dxPrev!;

    // Adaptive cutoff.
    final double cutoff = _minCutoff + _beta * dxHat.abs();
    final double alphaX = _alpha(dt, cutoff);
    final double xHat = alphaX * x + (1 - alphaX) * _xPrev!;

    _xPrev = xHat;
    _dxPrev = dxHat;
    _tPrev = t;
    return xHat;
  }

  void reset() {
    _xPrev = null;
    _dxPrev = null;
    _tPrev = null;
  }

  static double _alpha(double dt, double cutoff) {
    final double tau = 1.0 / (2.0 * pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }
}

/// Convenience: a filter pair for (x, y) of a single landmark.
class LandmarkFilter {
  final OneEuroFilter _fx = OneEuroFilter();
  final OneEuroFilter _fy = OneEuroFilter();

  (double, double) filter(double x, double y, double t) {
    return (_fx.filter(x, t), _fy.filter(y, t));
  }

  void reset() {
    _fx.reset();
    _fy.reset();
  }
}
