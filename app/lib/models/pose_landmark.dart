/// A single body landmark with normalised coordinates (0..1).
class PoseLandmark {
  /// ML Kit landmark type index (0-32).
  final int type;

  /// Normalised x in [0, 1] relative to frame width.
  final double x;

  /// Normalised y in [0, 1] relative to frame height.
  final double y;

  /// Detection confidence in [0, 1].
  final double confidence;

  const PoseLandmark({
    required this.type,
    required this.x,
    required this.y,
    required this.confidence,
  });
}
