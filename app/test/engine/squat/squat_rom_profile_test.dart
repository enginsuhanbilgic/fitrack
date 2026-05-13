import 'dart:convert';

import 'package:fitrack/core/constants.dart';
import 'package:fitrack/engine/squat/squat_rom_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SquatRomBucket — initialization', () {
    test('first sample seeds the bucket without smoothing', () {
      final b = SquatRomBucket.empty();
      // First rep: deep squat (min=80°) returning to standing (max=170°).
      final result = b.applyRep(80, 170);

      expect(result, RepApplyResult.initialized);
      expect(b.observedMinKneeAngle, 80);
      expect(b.observedMaxKneeAngle, 170);
      expect(b.sampleCount, 1);
      expect(b.recentMinSamples, [80]);
      expect(b.recentMaxSamples, [170]);
    });

    test('empty bucket reflects the global FSM defaults', () {
      final b = SquatRomBucket.empty();
      expect(b.observedMinKneeAngle, kSquatBottomAngle);
      expect(b.observedMaxKneeAngle, kSquatStartAngle);
      expect(b.sampleCount, 0);
      expect(b.femurTorsoRatio, isNull);
    });
  });

  group('SquatRomBucket — EMA expand (α=0.4)', () {
    test('a deeper bottom pulls observedMinKneeAngle down', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 90,
        observedMaxKneeAngle: 170,
        sampleCount: 1,
        recentMinSamples: [90],
        recentMaxSamples: [170],
      );

      // Deeper flexion: 90 → 85. Expand α = 0.4.
      // expected = 0.4*85 + 0.6*90 = 88.
      final result = b.applyRep(85, 170);

      expect(result, RepApplyResult.applied);
      expect(b.observedMinKneeAngle, closeTo(88, 1e-9));
      expect(b.observedMaxKneeAngle, 170);
      expect(b.sampleCount, 2);
    });

    test('a higher standing top pulls observedMaxKneeAngle up', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 85,
        observedMaxKneeAngle: 170,
        sampleCount: 1,
        recentMinSamples: [85],
        recentMaxSamples: [170],
      );

      // Bigger extension: 170 → 175. Expand α = 0.4.
      // expected = 0.4*175 + 0.6*170 = 172.
      final result = b.applyRep(85, 175);

      expect(result, RepApplyResult.applied);
      expect(b.observedMinKneeAngle, 85);
      expect(b.observedMaxKneeAngle, closeTo(172, 1e-9));
    });
  });

  group('SquatRomBucket — shrink-pending (α=0.1 after 3-rep confirm)', () {
    test('first shrink-direction rep is shrinkPending (not applied)', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 80,
        observedMaxKneeAngle: 170,
        sampleCount: 1,
        recentMinSamples: [80],
        recentMaxSamples: [170],
      );

      // Shallower bottom: 80 → 85 (positive shift = shrink toward higher angle).
      // First confirming shrink — should NOT apply EMA, just buffer.
      final result = b.applyRep(85, 170);

      expect(result, RepApplyResult.shrinkPending);
      // EMA NOT applied yet.
      expect(b.observedMinKneeAngle, 80);
    });

    test('third confirming shrink applies α=0.1 EMA', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 80,
        observedMaxKneeAngle: 170,
        sampleCount: 1,
        recentMinSamples: [80],
        recentMaxSamples: [170],
      );

      // Three consecutive shrink-direction reps on the bottom side.
      // First two are shrinkPending (max side stays exactly 170 → also
      // counts as shrink-pending, so result == shrinkPending overall).
      expect(b.applyRep(85, 170), RepApplyResult.shrinkPending);
      expect(b.applyRep(86, 170), RepApplyResult.shrinkPending);
      // Third shrink confirms — EMA fires (α=0.1).
      // expected = 0.1*87 + 0.9*80 = 80.7
      final result = b.applyRep(87, 170);

      expect(result, RepApplyResult.applied);
      expect(b.observedMinKneeAngle, closeTo(80.7, 1e-9));
      expect(b.sampleCount, 2);
    });
  });

  group('SquatRomBucket — MAD outlier rejection', () {
    test('rep that is outlier on BOTH dimensions returns rejectedOutlier', () {
      // Both windows seeded with natural variance so MAD has non-zero
      // spread on each dimension. Min window: [85,86,87,88,89] → MAD=1.
      // Max window: [167,168,170,172,173] → MAD=2. (A constant window
      // returns mad=0 from the guard in mad_outlier.dart, which would
      // make every sample "not outlier" — the assertion would dilute.)
      final b = SquatRomBucket(
        observedMinKneeAngle: 87,
        observedMaxKneeAngle: 170,
        sampleCount: 5,
        recentMinSamples: [85, 86, 87, 88, 89],
        recentMaxSamples: [167, 168, 170, 172, 173],
      );

      // (30, 250) is wildly outside both windows → MAD rejects both.
      final result = b.applyRep(30, 250);

      expect(result, RepApplyResult.rejectedOutlier);
      expect(b.observedMinKneeAngle, 87);
      expect(b.observedMaxKneeAngle, 170);
    });

    test('a min-side outlier with non-outlier max returns shrinkPending', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 87,
        observedMaxKneeAngle: 170,
        sampleCount: 5,
        recentMinSamples: [85, 86, 87, 88, 89],
        recentMaxSamples: [167, 168, 170, 172, 173],
      );

      // 30 is min-side outlier; 170 is in distribution (and equals the
      // observed max, so the max side flows through as shrink-pending).
      final result = b.applyRep(30, 170);
      expect(result, RepApplyResult.shrinkPending);
      expect(b.observedMinKneeAngle, 87);
    });

    test('MAD-rejected sample still updates the recent-samples window', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 87,
        observedMaxKneeAngle: 170,
        sampleCount: 5,
        recentMinSamples: [85, 86, 87, 88, 89],
        recentMaxSamples: [167, 168, 170, 172, 173],
      );

      b.applyRep(30, 250);
      // The outlier still appends to the FIFO buffer so future distribution
      // shifts are detectable. Both windows now contain the rejected sample.
      expect(b.recentMinSamples, contains(30));
      expect(b.recentMaxSamples, contains(250));
    });
  });

  group('SquatRomBucket — MAD suppression while shrink-pending', () {
    test('a shrink-direction sample is NOT MAD-rejected when '
        'shrink-pending is already in flight', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 80,
        observedMaxKneeAngle: 170,
        sampleCount: 5,
        recentMinSamples: [80, 80, 80, 80, 80],
        recentMaxSamples: [170, 170, 170, 170, 170],
      );

      // First shrink rep — shrinkPending.
      expect(b.applyRep(82, 170), RepApplyResult.shrinkPending);
      // Second shrink rep at 90° — would be a MAD outlier vs window of
      // mostly-80 samples normally, but MAD is SUPPRESSED here because
      // _consecutiveShrinkCandidatesMin > 0.
      expect(b.applyRep(90, 170), RepApplyResult.shrinkPending);
      // Verify by checking the third confirming shrink fires EMA (i.e.,
      // the prior shrink was not MAD-rejected mid-stream).
      final third = b.applyRep(95, 170);
      expect(third, RepApplyResult.applied);
      // EMA fires with the third sample, α=0.1:
      // expected = 0.1*95 + 0.9*80 = 81.5
      expect(b.observedMinKneeAngle, closeTo(81.5, 1e-9));
    });
  });

  group('SquatRomBucket — JSON round-trip', () {
    test('round-trip preserves shrink counters and femurTorsoRatio', () {
      final b = SquatRomBucket(
        observedMinKneeAngle: 84.2,
        observedMaxKneeAngle: 172.5,
        sampleCount: 7,
        femurTorsoRatio: 0.68,
        recentMinSamples: [80, 82, 84, 85, 84.2],
        recentMaxSamples: [170, 171, 172, 173, 172.5],
        consecutiveShrinkCandidatesMin: 2,
        consecutiveShrinkCandidatesMax: 1,
      );

      final encoded = jsonEncode(b.toJson());
      final decoded = SquatRomBucket.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );

      expect(decoded.observedMinKneeAngle, closeTo(84.2, 1e-9));
      expect(decoded.observedMaxKneeAngle, closeTo(172.5, 1e-9));
      expect(decoded.sampleCount, 7);
      expect(decoded.femurTorsoRatio, closeTo(0.68, 1e-9));
      expect(decoded.recentMinSamples, [80, 82, 84, 85, 84.2]);
      expect(decoded.recentMaxSamples, [170, 171, 172, 173, 172.5]);

      // Continue the shrink-counter behavior post-deserialization. Two more
      // consecutive shrink-direction reps should fire the EMA (we restored
      // _consecutiveShrinkCandidatesMin = 2, so the next confirms = 3).
      final result = decoded.applyRep(86, 172.5);
      expect(result, RepApplyResult.applied);
    });

    test('round-trip preserves null femurTorsoRatio', () {
      final b = SquatRomBucket.empty();
      b.applyRep(85, 170); // seed sample, no ratio set

      final encoded = jsonEncode(b.toJson());
      final decoded = SquatRomBucket.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );
      expect(decoded.femurTorsoRatio, isNull);
    });
  });

  group('SquatRomProfile — calibration gate + JSON', () {
    test('isCalibrated is false when bucket is null', () {
      final p = SquatRomProfile();
      expect(p.isCalibrated, isFalse);
    });

    test('isCalibrated is false when bucket has < kSquatCalibrationMinReps '
        'samples', () {
      final p = SquatRomProfile(
        bucket: SquatRomBucket(
          observedMinKneeAngle: 85,
          observedMaxKneeAngle: 170,
          sampleCount: kSquatCalibrationMinReps - 1,
        ),
      );
      expect(p.isCalibrated, isFalse);
    });

    test('isCalibrated is true at exactly kSquatCalibrationMinReps', () {
      final p = SquatRomProfile(
        bucket: SquatRomBucket(
          observedMinKneeAngle: 85,
          observedMaxKneeAngle: 170,
          sampleCount: kSquatCalibrationMinReps,
        ),
      );
      expect(p.isCalibrated, isTrue);
    });

    test('JSON round-trip preserves bucket', () {
      final original = SquatRomProfile(
        userId: 'alice',
        bucket: SquatRomBucket(
          observedMinKneeAngle: 82.0,
          observedMaxKneeAngle: 175.0,
          sampleCount: 5,
          femurTorsoRatio: 0.72,
        ),
      );

      final encoded = jsonEncode(original.toJson());
      final decoded = SquatRomProfile.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );

      expect(decoded.userId, 'alice');
      expect(decoded.bucket, isNotNull);
      expect(decoded.bucket!.observedMinKneeAngle, 82.0);
      expect(decoded.bucket!.observedMaxKneeAngle, 175.0);
      expect(decoded.bucket!.sampleCount, 5);
      expect(decoded.bucket!.femurTorsoRatio, 0.72);
    });

    test('JSON round-trip preserves null bucket', () {
      final original = SquatRomProfile();

      final encoded = jsonEncode(original.toJson());
      final decoded = SquatRomProfile.fromJson(
        jsonDecode(encoded) as Map<String, dynamic>,
      );

      expect(decoded.bucket, isNull);
      expect(decoded.userId, 'local_user');
    });

    test('schema mismatch throws StateError', () {
      final j = {
        'schemaVersion': 999,
        'userId': 'x',
        'createdAt': DateTime.now().toIso8601String(),
        'lastUsedAt': DateTime.now().toIso8601String(),
        'bucket': null,
      };
      expect(() => SquatRomProfile.fromJson(j), throwsA(isA<StateError>()));
    });
  });
}
