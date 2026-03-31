import '../models/pose_landmark.dart';
import 'one_euro_filter.dart';

/// Applies per-landmark 1€ filtering to reduce jitter on the skeleton overlay.
class LandmarkSmoother {
  final Map<int, LandmarkFilter> _filters = {};
  final Stopwatch _clock = Stopwatch()..start();

  /// Returns a new list of landmarks with smoothed (x, y).
  List<PoseLandmark> smooth(List<PoseLandmark> raw) {
    final double t = _clock.elapsedMilliseconds / 1000.0;

    return raw.map((lm) {
      final filter =
          _filters.putIfAbsent(lm.type, () => LandmarkFilter());
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
