/// Pure-Dart isolation tests for the JSON round-trip used by the
/// VM's `_cloneBucketForOtherSide` helper.
///
/// The Global Calibration flow duplicates the chosen-side bucket into
/// the opposite side via `RomBucket.fromJson(jsonDecode(jsonEncode(...)))`.
/// If `fromJson` shares any inner list aliases with the source, mutating
/// one bucket's `recentMinSamples` / `recentMaxSamples` would silently
/// corrupt the other — and a future `applyRep` on the original would
/// surface as a phantom mutation on the clone.
///
/// These tests pin the contract: a JSON round-trip is a true deep copy.
library;

import 'dart:convert';

import 'package:fitrack/core/types.dart';
import 'package:fitrack/engine/curl/curl_rom_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RomBucket — JSON round-trip deep copy', () {
    test(
      'mutating source.recentMinSamples does NOT affect clone.recentMinSamples',
      () {
        final source = RomBucket.empty(
          ProfileSide.left,
          CurlCameraView.sideLeft,
        );
        source.applyRep(50, 165);
        source.applyRep(52, 167);

        final clone = RomBucket.fromJson(
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
        );

        // Sanity: equal contents pre-mutation.
        expect(clone.recentMinSamples, source.recentMinSamples);
        expect(
          identical(clone.recentMinSamples, source.recentMinSamples),
          isFalse,
          reason: 'fromJson must produce a fresh list, not an alias',
        );

        source.recentMinSamples.add(99);
        expect(
          clone.recentMinSamples.contains(99),
          isFalse,
          reason: 'mutation on source must not leak into the clone',
        );
      },
    );

    test(
      'mutating source.recentMaxSamples does NOT affect clone.recentMaxSamples',
      () {
        final source = RomBucket.empty(
          ProfileSide.right,
          CurlCameraView.sideRight,
        );
        source.applyRep(48, 170);
        source.applyRep(46, 172);

        final clone = RomBucket.fromJson(
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>,
        );

        source.recentMaxSamples.removeLast();
        expect(
          clone.recentMaxSamples.length,
          source.recentMaxSamples.length + 1,
          reason: 'shrinking source must not shrink the clone',
        );
      },
    );

    test('changing the JSON `side` field before fromJson lets us reuse the '
        'same bucket for the opposite side without mutating the source', () {
      // Mirrors what `_cloneBucketForOtherSide` does in the VM.
      final source = RomBucket.empty(ProfileSide.left, CurlCameraView.sideLeft);
      source.applyRep(50, 165);
      source.applyRep(48, 167);
      source.applyRep(52, 168);

      final json =
          jsonDecode(jsonEncode(source.toJson())) as Map<String, dynamic>;
      json['side'] = ProfileSide.right.name;
      final clone = RomBucket.fromJson(json);

      expect(clone.side, ProfileSide.right);
      expect(source.side, ProfileSide.left);
      expect(clone.observedMinAngle, source.observedMinAngle);
      expect(clone.observedMaxAngle, source.observedMaxAngle);
      expect(clone.sampleCount, source.sampleCount);
      // Bucket key reflects the new side.
      expect(
        clone.key,
        RomBucket.keyFor(ProfileSide.right, CurlCameraView.sideLeft),
      );
    });
  });
}
