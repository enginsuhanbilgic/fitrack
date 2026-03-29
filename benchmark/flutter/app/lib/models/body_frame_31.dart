import 'dart:convert';
import 'pose_landmark.dart';
import 'pose_result.dart';

/// Represents a standardized "Body Frame 3.1" for Gemini 3.1 Pro analysis.
/// Optimized for the 'gemini-3.1-pro-preview-customtools' endpoint.
class BodyFrame31 {
  final int frameIndex;
  final List<PoseLandmark> landmarks;
  final Map<String, double>? normalizedCoordinates;

  BodyFrame31({
    required this.frameIndex,
    required this.landmarks,
    this.normalizedCoordinates,
  });

  /// Convert a MoveNet PoseResult into a Gemini-optimized JSON frame.
  /// Normalizes coordinates relative to the "Mid-Hip" (origin) and
  /// "Torso Length" (scale).
  Map<String, dynamic> toJson() {
    if (landmarks.isEmpty) return {'f': frameIndex, 'valid': false};

    // Find anchor points for normalization
    final leftHip = landmarks.firstWhere((l) => l.type == 11, orElse: () => landmarks[0]);
    final rightHip = landmarks.firstWhere((l) => l.type == 12, orElse: () => landmarks[0]);
    final leftShoulder = landmarks.firstWhere((l) => l.type == 5, orElse: () => landmarks[0]);
    final rightShoulder = landmarks.firstWhere((l) => l.type == 6, orElse: () => landmarks[0]);

    // Calculate Mid-Hip (Origin)
    final double originX = (leftHip.x + rightHip.x) / 2;
    final double originY = (leftHip.y + rightHip.y) / 2;

    // Calculate Torso Scale (Distance from hips to shoulders)
    final double hipY = originY;
    final double shoulderY = (leftShoulder.y + rightShoulder.y) / 2;
    final double torsoScale = (hipY - shoulderY).abs().clamp(0.01, 1.0);

    final List<Map<String, dynamic>> kps = [];
    for (final lm in landmarks) {
      // Relative to origin, scaled by torso
      final double relX = (lm.x - originX) / torsoScale;
      final double relY = (lm.y - originY) / torsoScale;

      kps.add({
        't': lm.type,
        'x': double.parse(relX.toStringAsFixed(3)),
        'y': double.parse(relY.toStringAsFixed(3)),
        'c': double.parse(lm.confidence.toStringAsFixed(2)),
      });
    }

    return {
      'f': frameIndex,
      'kps': kps,
      'scale': double.parse(torsoScale.toStringAsFixed(3)),
    };
  }
}

/// Helper to serialize a sequence of frames for Gemini 3.1 Pro.
String serializeBodySequence(List<PoseResult> results) {
  final List<Map<String, dynamic>> frames = [];
  for (int i = 0; i < results.length; i++) {
    frames.add(BodyFrame31(frameIndex: i, landmarks: results[i].landmarks).toJson());
  }
  return jsonEncode({
    'model': 'gemini-3.1-pro-pose-v1', // Exact frame model identifier
    'v': '3.1',
    'frames': frames,
  });
}
