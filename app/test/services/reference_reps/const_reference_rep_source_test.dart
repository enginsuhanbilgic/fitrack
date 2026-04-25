import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/reference_reps/reference_rep_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const source = ConstReferenceRepSource();

  group('ConstReferenceRepSource', () {
    test('front view returns a 64-sample list', () {
      final series = source.forBucket(CurlCameraView.front);
      expect(series, isNotNull);
      expect(series!.length, 64);
    });

    test('sideLeft view returns a 64-sample list', () {
      final series = source.forBucket(CurlCameraView.sideLeft);
      expect(series, isNotNull);
      expect(series!.length, 64);
    });

    test('sideRight view returns null (not yet in dataset)', () {
      expect(source.forBucket(CurlCameraView.sideRight), isNull);
    });

    test('unknown view returns null', () {
      expect(source.forBucket(CurlCameraView.unknown), isNull);
    });

    test('front series starts near full extension and has a mid-rep trough', () {
      final series = source.forBucket(CurlCameraView.front)!;
      // The trace should begin near full extension (> 140°).
      expect(series.first, greaterThan(140.0));
      // There should be a minimum somewhere in the middle (peak of curl, < 60°).
      expect(series.reduce((a, b) => a < b ? a : b), lessThan(60.0));
    });

    test(
      'sideLeft series starts near full extension and has a mid-rep trough',
      () {
        final series = source.forBucket(CurlCameraView.sideLeft)!;
        expect(series.first, greaterThan(140.0));
        expect(series.reduce((a, b) => a < b ? a : b), lessThan(60.0));
      },
    );

    test('returned list is immutable (const)', () {
      final series = source.forBucket(CurlCameraView.front)!;
      expect(() => series.add(0.0), throwsUnsupportedError);
    });
  });
}
