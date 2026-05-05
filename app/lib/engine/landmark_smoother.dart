import '../core/constants.dart';
import '../models/pose_landmark.dart';
import 'one_euro_filter.dart';

/// Applies per-landmark 1€ filtering to reduce jitter on the skeleton overlay.
///
/// The default constructor uses the paper's generic defaults from
/// [constants.dart]. Use named parameters to construct a display-only smoother
/// with aggressive cutoffs — this instance is independent from any smoother
/// the engine pipeline may use in future, so tuning here cannot cause rep
/// detection regressions.
class LandmarkSmoother {
  final double _minCutoff;
  final double _beta;
  final double _dCutoff;

  final Map<int, LandmarkFilter> _filters = {};
  final Stopwatch _clock = Stopwatch()..start();

  LandmarkSmoother({
    double minCutoff = kOneEuroMinCutoff,
    double beta = kOneEuroBeta,
    double dCutoff = kOneEuroDCutoff,
  }) : _minCutoff = minCutoff,
       _beta = beta,
       _dCutoff = dCutoff;

  /// Returns a new list of landmarks with smoothed (x, y).
  List<PoseLandmark> smooth(List<PoseLandmark> raw) {
    final double t = _clock.elapsedMilliseconds / 1000.0;

    return raw.map((lm) {
      final filter = _filters.putIfAbsent(
        lm.type,
        () => LandmarkFilter(
          minCutoff: _minCutoff,
          beta: _beta,
          dCutoff: _dCutoff,
        ),
      );
      final (sx, sy) = filter.filter(lm.x, lm.y, t);
      return PoseLandmark(
        type: lm.type,
        x: sx,
        y: sy,
        confidence: lm.confidence,
      );
    }).toList();
  }

  void reset() {
    for (final f in _filters.values) {
      f.reset();
    }
    _filters.clear();
    _clock.reset();
    _clock.start();
  }
}
