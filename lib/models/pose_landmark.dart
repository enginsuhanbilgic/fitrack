class PoseLandmark {
  final int type;
  final double x; // normalized 0..1
  final double y; // normalized 0..1
  final double confidence;

  const PoseLandmark({
    required this.type,
    required this.x,
    required this.y,
    required this.confidence,
  });

  @override
  String toString() => 'PoseLandmark(type=$type, x=${x.toStringAsFixed(3)}, y=${y.toStringAsFixed(3)}, conf=${confidence.toStringAsFixed(2)})';
}
