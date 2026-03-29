import '../models/pose_landmark.dart';

/// Per-keypoint Exponential Moving Average smoother.
///
/// Each landmark's x/y is blended with its previous smoothed position:
///   smoothed = alpha * incoming + (1 - alpha) * previous
///
/// A higher [alpha] (→ 1.0) tracks movement faster with less smoothing.
/// A lower [alpha] (→ 0.0) is smoother but lags behind fast motion.
/// 0.4 is a good default for pose overlays: dampens frame-to-frame jitter
/// while still following real movement within 2–3 frames.
class LandmarkSmoother {
  final double alpha;

  // Keyed by landmark type index → last smoothed (x, y, confidence).
  final Map<int, _SmoothedLandmark> _state = {};

  LandmarkSmoother({this.alpha = 0.4});

  /// Apply EMA smoothing. Returns new list with smoothed coordinates.
  /// Pass an empty list to reset state (person left the frame).
  List<PoseLandmark> smooth(List<PoseLandmark> landmarks) {
    if (landmarks.isEmpty) {
      _state.clear();
      return landmarks;
    }

    return landmarks.map((lm) {
      final prev = _state[lm.type];
      if (prev == null) {
        // First observation — no prior state, use raw value as-is.
        _state[lm.type] = _SmoothedLandmark(lm.x, lm.y, lm.confidence);
        return lm;
      }

      final sx = alpha * lm.x + (1.0 - alpha) * prev.x;
      final sy = alpha * lm.y + (1.0 - alpha) * prev.y;
      final sc = alpha * lm.confidence + (1.0 - alpha) * prev.confidence;

      _state[lm.type] = _SmoothedLandmark(sx, sy, sc);

      return PoseLandmark(type: lm.type, x: sx, y: sy, confidence: sc);
    }).toList();
  }

  void reset() => _state.clear();
}

class _SmoothedLandmark {
  final double x, y, confidence;
  const _SmoothedLandmark(this.x, this.y, this.confidence);
}
