import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/summary_insights.dart';
import 'package:fitrack/core/types.dart';

BicepsSideRepMetrics _rep({
  double? elbowRiseRatio,
  double? shoulderDriftRatio,
  double? backLeanDeg,
  double? shrugRatio,
  int repIndex = 0,
}) => BicepsSideRepMetrics(
  repIndex: repIndex,
  leanDeg: null,
  shoulderDriftRatio: shoulderDriftRatio,
  elbowDriftRatio: null,
  backLeanDeg: backLeanDeg,
  shrugRatio: shrugRatio,
  elbowRiseRatio: elbowRiseRatio,
);

void main() {
  group('buildCurlInsights — zero reps', () {
    test('returns single no-rep message and nothing else', () {
      final out = buildCurlInsights(
        totalReps: 0,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      expect(out, hasLength(1));
      expect(out.first, contains('No reps were counted'));
    });

    test('ignores all other flags when totalReps == 0', () {
      final out = buildCurlInsights(
        totalReps: 0,
        eccentricTooFastCount: 5,
        fatigueDetected: true,
        asymmetryDetected: true,
        averageQuality: 0.9,
        errorsTriggered: {FormError.elbowDrift},
      );
      expect(out, hasLength(1));
      expect(out.first, contains('No reps were counted'));
    });
  });

  group('buildCurlInsights — eccentric tempo', () {
    test('majority fast → "most reps" wording', () {
      final out = buildCurlInsights(
        totalReps: 4,
        eccentricTooFastCount: 3,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      expect(out.any((s) => s.contains('most reps')), isTrue);
    });

    test('minority fast → exact count wording', () {
      final out = buildCurlInsights(
        totalReps: 10,
        eccentricTooFastCount: 2,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      expect(out.any((s) => s.contains('2 rep(s)')), isTrue);
    });

    test('zero fast → no eccentric insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
      );
      expect(out.any((s) => s.contains('lowering')), isFalse);
    });
  });

  group('buildCurlInsights — fatigue and asymmetry', () {
    test('fatigue flag → fatigue insight present', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: true,
        asymmetryDetected: false,
      );
      expect(out.any((s) => s.contains('Fatigue')), isTrue);
    });

    test('asymmetry flag → asymmetry insight present', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: true,
      );
      expect(out.any((s) => s.contains('uneven range')), isTrue);
    });
  });

  group('buildCurlInsights — side-view metrics', () {
    test('elbow rise above threshold → elbow rise insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [_rep(elbowRiseRatio: kElbowRiseThreshold + 0.05)],
      );
      expect(out.any((s) => s.contains('elbow rose')), isTrue);
    });

    test('elbow rise at or below threshold → no elbow rise insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [_rep(elbowRiseRatio: kElbowRiseThreshold)],
      );
      expect(out.any((s) => s.contains('elbow rose')), isFalse);
    });

    test('shoulder arc above threshold → shoulder swing insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [_rep(shoulderDriftRatio: kSwingThreshold + 0.05)],
      );
      expect(out.any((s) => s.contains('swung your shoulder')), isTrue);
    });

    test('back lean above threshold → back lean insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [_rep(backLeanDeg: kBackLeanThresholdDeg + 1.0)],
      );
      expect(out.any((s) => s.contains('leaned back')), isTrue);
    });

    test('shrug above threshold → shrug insight', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [_rep(shrugRatio: kShrugThreshold + 0.05)],
      );
      expect(out.any((s) => s.contains('shrugged')), isTrue);
    });

    test('avg across reps is used — only avg above threshold triggers', () {
      // Rep 0: elbowRise = 0.30 (above 0.18), Rep 1: 0.06 (below)
      // avg = 0.18 → exactly at threshold, should NOT trigger
      final out = buildCurlInsights(
        totalReps: 2,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: [
          _rep(elbowRiseRatio: 0.30, repIndex: 0),
          _rep(elbowRiseRatio: 0.06, repIndex: 1),
        ],
      );
      expect(out.any((s) => s.contains('elbow rose')), isFalse);
    });

    test('no side metrics → no side-view insight fired', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        sideMetrics: const [],
      );
      expect(out.any((s) => s.contains('elbow rose')), isFalse);
      expect(out.any((s) => s.contains('swung')), isFalse);
      expect(out.any((s) => s.contains('leaned back')), isFalse);
      expect(out.any((s) => s.contains('shrugged')), isFalse);
    });
  });

  group('buildCurlInsights — fallback insight', () {
    test('clean session → great session message', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        averageQuality: 0.90,
        errorsTriggered: const {},
      );
      expect(out.any((s) => s.contains('Great session')), isTrue);
    });

    test('errors present and quality low → review message', () {
      final out = buildCurlInsights(
        totalReps: 5,
        eccentricTooFastCount: 0,
        fatigueDetected: false,
        asymmetryDetected: false,
        averageQuality: 0.60,
        errorsTriggered: {FormError.elbowDrift},
      );
      expect(out.any((s) => s.contains('Review the form issues')), isTrue);
    });
  });
}
