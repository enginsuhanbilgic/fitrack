import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';

void main() {
  group('RomBucket — initialization', () {
    test('first sample seeds the bucket without smoothing', () {
      final b = RomBucket.empty(ProfileSide.left, CurlCameraView.front);
      final result = b.applyRep(60, 165);

      expect(result, RepApplyResult.initialized);
      expect(b.observedMinAngle, 60);
      expect(b.observedMaxAngle, 165);
      expect(b.sampleCount, 1);
      expect(b.recentMinSamples, [60]);
      expect(b.recentMaxSamples, [165]);
    });

    test('empty bucket key matches the static helper', () {
      final b = RomBucket.empty(ProfileSide.right, CurlCameraView.sideRight);
      expect(
        b.key,
        RomBucket.keyFor(ProfileSide.right, CurlCameraView.sideRight),
      );
      expect(b.key, 'right_sideRight');
    });
  });

  group('RomBucket — EMA expand', () {
    test('a deeper peak pulls observedMinAngle down by α·(new−old)', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 80,
        observedMaxAngle: 165,
        sampleCount: 1,
        recentMinSamples: [80],
        recentMaxSamples: [165],
      );

      // Deeper flexion: 80 → 60. Expand α = 0.4.
      // expected = 0.4*60 + 0.6*80 = 72.
      final result = b.applyRep(60, 165);

      expect(result, RepApplyResult.applied);
      expect(b.observedMinAngle, closeTo(72, 1e-9));
      // Rest unchanged because thisRepMax == observedMax (no expand path).
      expect(b.observedMaxAngle, 165);
    });

    test('a fuller rest pulls observedMaxAngle up by α·(new−old)', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 150,
        sampleCount: 1,
        recentMinSamples: [60],
        recentMaxSamples: [150],
      );

      // More extended: 150 → 170. Expand α = 0.4.
      // expected = 0.4*170 + 0.6*150 = 158.
      b.applyRep(60, 170);

      expect(b.observedMaxAngle, closeTo(158, 1e-9));
    });
  });

  group('RomBucket — EMA shrink (with confirmation)', () {
    test('shallower-than-bucket peaks are held pending until '
        'kProfileShrinkConfirmReps consecutive samples', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 165,
        sampleCount: 5,
        // Pre-warm the recent window so MAD outlier guard activates.
        recentMinSamples: [60, 61, 59, 60, 60],
        recentMaxSamples: [165, 164, 166, 165, 165],
      );

      // 1st shallow rep — pending.
      var r = b.applyRep(75, 165);
      expect(r, RepApplyResult.shrinkPending);
      expect(b.observedMinAngle, 60);

      // 2nd shallow rep — still pending (kProfileShrinkConfirmReps = 3).
      r = b.applyRep(76, 165);
      expect(r, RepApplyResult.shrinkPending);
      expect(b.observedMinAngle, 60);

      // 3rd shallow rep — confirms. EMA applied with shrink α = 0.1.
      // expected = 0.1*77 + 0.9*60 = 7.7 + 54 = 61.7
      r = b.applyRep(77, 165);
      expect(r, RepApplyResult.applied);
      expect(b.observedMinAngle, closeTo(61.7, 1e-9));
    });

    test('a single deep expand resets the shrink-confirm counter', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 165,
        sampleCount: 5,
        recentMinSamples: [60, 61, 59, 60, 60],
        recentMaxSamples: [165, 164, 166, 165, 165],
      );

      b.applyRep(75, 165); // pending #1
      b.applyRep(76, 165); // pending #2
      b.applyRep(58, 165); // EXPAND — counter resets
      // Now a shallow rep is back to pending #1, not #3.
      final r = b.applyRep(75, 165);
      expect(r, RepApplyResult.shrinkPending);
    });
  });

  group('RomBucket — outlier rejection (median + MAD)', () {
    test('a sample far from the median is rejected and EMA is not applied', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 165,
        sampleCount: 8,
        recentMinSamples: [60, 61, 59, 60, 62, 58, 60, 61],
        recentMaxSamples: [165, 166, 164, 165, 167, 163, 165, 166],
      );

      // Wildly off — half rep / phantom sample.
      final r = b.applyRep(20, 90);

      expect(r, RepApplyResult.rejectedOutlier);
      expect(b.observedMinAngle, 60); // unchanged
      expect(b.observedMaxAngle, 165); // unchanged
    });

    test('outlier-rejected samples are still appended to recent buffers', () {
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 165,
        sampleCount: 8,
        recentMinSamples: [60, 61, 59, 60, 62, 58, 60, 61],
        recentMaxSamples: [165, 166, 164, 165, 167, 163, 165, 166],
      );

      b.applyRep(20, 90);

      // Window capped at kProfileOutlierWindow = 8. Oldest dropped, new appended.
      expect(b.recentMinSamples.length, kProfileOutlierWindow);
      expect(b.recentMinSamples.last, 20);
      expect(b.recentMaxSamples.last, 90);
    });

    test('outlier guard is disabled until window has ≥ 4 samples', () {
      final b = RomBucket.empty(ProfileSide.left, CurlCameraView.front)
        ..applyRep(60, 165) // initialize
        ..applyRep(60, 165) // 2 samples
        ..applyRep(60, 165); // 3 samples

      // 4th sample — even an extreme value should not be guarded.
      final r = b.applyRep(20, 200);
      expect(r, isNot(RepApplyResult.rejectedOutlier));
    });
  });

  group('CurlRomProfile — bucket lookup + insertion', () {
    test('bucketFor returns null when bucket missing', () {
      final p = CurlRomProfile();
      expect(p.bucketFor(ProfileSide.left, CurlCameraView.front), isNull);
    });

    test('upsertBucket is idempotent on key collision', () {
      final p = CurlRomProfile();
      final b1 = RomBucket.empty(ProfileSide.left, CurlCameraView.front);
      final b2 = RomBucket.empty(ProfileSide.left, CurlCameraView.front);
      p.upsertBucket(b1);
      p.upsertBucket(b2);
      expect(p.buckets.length, 1);
      expect(
        identical(p.bucketFor(ProfileSide.left, CurlCameraView.front), b2),
        isTrue,
      );
    });

    test('isCalibrated requires kCalibrationMinReps samples', () {
      final p = CurlRomProfile();
      final b = RomBucket(
        side: ProfileSide.left,
        view: CurlCameraView.front,
        observedMinAngle: 60,
        observedMaxAngle: 165,
        sampleCount: kCalibrationMinReps - 1,
      );
      p.upsertBucket(b);
      expect(p.isCalibrated(ProfileSide.left, CurlCameraView.front), isFalse);

      b.sampleCount = kCalibrationMinReps;
      expect(p.isCalibrated(ProfileSide.left, CurlCameraView.front), isTrue);
    });
  });

  group('CurlRomProfile — JSON round-trip', () {
    test('serializes and deserializes without losing fidelity', () {
      final original = CurlRomProfile(userId: 'local_user');
      final b = RomBucket(
        side: ProfileSide.right,
        view: CurlCameraView.sideRight,
        observedMinAngle: 65.5,
        observedMaxAngle: 162.3,
        sampleCount: 12,
        recentMinSamples: [65, 66, 65, 64, 67, 65, 66, 65],
        recentMaxSamples: [162, 163, 161, 162, 164, 162, 163, 162],
      );
      original.upsertBucket(b);

      final json = jsonEncode(original.toJson());
      final restored = CurlRomProfile.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );

      final rb = restored.bucketFor(
        ProfileSide.right,
        CurlCameraView.sideRight,
      )!;
      expect(rb.observedMinAngle, 65.5);
      expect(rb.observedMaxAngle, 162.3);
      expect(rb.sampleCount, 12);
      expect(rb.recentMinSamples, b.recentMinSamples);
      expect(rb.recentMaxSamples, b.recentMaxSamples);
      expect(restored.userId, 'local_user');
    });

    test('schema mismatch throws StateError', () {
      final j = {
        'schemaVersion': 999,
        'userId': 'local_user',
        'createdAt': DateTime.now().toIso8601String(),
        'lastUsedAt': DateTime.now().toIso8601String(),
        'buckets': <Map<String, dynamic>>[],
      };
      expect(() => CurlRomProfile.fromJson(j), throwsStateError);
    });
  });

  group('ProfileSummary', () {
    test('reports zero counts on an empty profile', () {
      final s = ProfileSummary.of(CurlRomProfile());
      expect(s.totalBuckets, 0);
      expect(s.calibratedBuckets, 0);
    });

    test('counts only calibrated buckets above threshold', () {
      final p = CurlRomProfile();
      p.upsertBucket(
        RomBucket(
          side: ProfileSide.left,
          view: CurlCameraView.front,
          observedMinAngle: 60,
          observedMaxAngle: 165,
          sampleCount: kCalibrationMinReps,
        ),
      );
      p.upsertBucket(
        RomBucket(
          side: ProfileSide.right,
          view: CurlCameraView.front,
          observedMinAngle: 60,
          observedMaxAngle: 165,
          sampleCount: kCalibrationMinReps - 1,
        ),
      );

      final s = ProfileSummary.of(p);
      expect(s.totalBuckets, 2);
      expect(s.calibratedBuckets, 1);
    });
  });
}
