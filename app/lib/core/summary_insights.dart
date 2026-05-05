import 'constants.dart';
import 'types.dart';

/// Returns coaching insight strings for a curl session.
///
/// Pure function — no widget or BuildContext dependency. All inputs are
/// value types so this can be unit-tested without a Flutter environment.
///
/// [totalReps]           — committed rep count this session
/// [eccentricTooFastCount] — reps where eccentric phase was too fast
/// [fatigueDetected]     — true when the fatigue baseline fired
/// [asymmetryDetected]   — true when left/right ROM diverged
/// [averageQuality]      — session-level quality score 0–1, nullable
/// [errorsTriggered]     — set of [FormError] that fired at least once
/// [sideMetrics]         — per-rep [BicepsSideRepMetrics]; empty for front view
List<String> buildCurlInsights({
  required int totalReps,
  required int eccentricTooFastCount,
  required bool fatigueDetected,
  required bool asymmetryDetected,
  double? averageQuality,
  Set<FormError> errorsTriggered = const {},
  List<BicepsSideRepMetrics> sideMetrics = const [],
}) {
  final insights = <String>[];

  if (totalReps == 0) {
    insights.add(
      'No reps were counted. Make sure your full arm — shoulder, '
      'elbow, and wrist — stays in frame throughout the curl. Try '
      'stepping back from the camera or rotating to landscape.',
    );
    return insights;
  }

  if (eccentricTooFastCount > totalReps * 0.5) {
    insights.add(
      'You rushed the lowering phase on most reps. Try a 2-second count on the way down.',
    );
  } else if (eccentricTooFastCount > 0) {
    insights.add(
      'You rushed the lowering on $eccentricTooFastCount rep(s). Slow, controlled lowering builds more muscle.',
    );
  }

  if (fatigueDetected) {
    insights.add(
      'Fatigue detected mid-session. Consider shorter sets with full recovery between them.',
    );
  }

  if (asymmetryDetected) {
    insights.add(
      'Your arms showed uneven range. Focus on matching both sides for balanced development.',
    );
  }

  // Side-view specific coaching.
  if (sideMetrics.isNotEmpty) {
    double? avg(double? Function(BicepsSideRepMetrics) pick) {
      final vals = sideMetrics.map(pick).whereType<double>().toList();
      if (vals.isEmpty) return null;
      return vals.reduce((a, b) => a + b) / vals.length;
    }

    final avgElbowRise = avg((r) => r.elbowRiseRatio);
    if (avgElbowRise != null && avgElbowRise > kElbowRiseThreshold) {
      insights.add(
        'Your elbow rose during the curl. Keep it pinned to your side — '
        'lifting it shifts load away from the bicep.',
      );
    }

    final avgShoulderArc = avg((r) => r.shoulderDriftRatio);
    if (avgShoulderArc != null && avgShoulderArc > kSwingThreshold) {
      insights.add(
        'You swung your shoulder into the lift. Start each rep with the '
        'elbow still and use only forearm flexion.',
      );
    }

    final avgBackLean = avg((r) => r.backLeanDeg);
    if (avgBackLean != null && avgBackLean > kBackLeanThresholdDeg) {
      insights.add(
        'You leaned back to complete the curl. Reduce the weight and keep '
        'your torso upright throughout.',
      );
    }

    final avgShrug = avg((r) => r.shrugRatio);
    if (avgShrug != null && avgShrug > kShrugThreshold) {
      insights.add(
        'Your shoulder shrugged on most reps. Depress your shoulder blade '
        'before curling to isolate the bicep.',
      );
    }
  }

  if (errorsTriggered.isEmpty ||
      averageQuality != null && averageQuality >= 0.85) {
    insights.add('Great session! Keep this tempo and range of motion.');
  }

  if (insights.isEmpty) {
    if (averageQuality != null && averageQuality >= 0.85) {
      insights.add('Great session! Keep this tempo and range of motion.');
    } else {
      insights.add(
        'Review the form issues above and focus on one correction at a time.',
      );
    }
  }

  return insights;
}
