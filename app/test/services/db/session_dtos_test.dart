import 'package:fitrack/core/types.dart';
import 'package:fitrack/services/db/session_dtos.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RepRow.toCurlRepRecord', () {
    test('returns null when any required curl field is null', () {
      final fullRow = RepRow(
        repIndex: 1,
        quality: 0.8,
        minAngle: 50,
        maxAngle: 160,
        side: ProfileSide.left,
        view: CurlCameraView.front,
        source: ThresholdSource.calibrated,
        bucketUpdated: true,
        rejectedOutlier: false,
      );
      expect(fullRow.toCurlRepRecord(), isNotNull);

      // Swap out each required field one at a time — all must individually
      // force null, locking the null-contract.
      expect(
        RepRow(
          repIndex: 1,
          minAngle: 50,
          maxAngle: 160,
          view: CurlCameraView.front,
          source: ThresholdSource.calibrated,
          bucketUpdated: true,
          rejectedOutlier: false,
        ).toCurlRepRecord(),
        isNull,
        reason: 'side missing',
      );
      expect(
        RepRow(
          repIndex: 1,
          minAngle: 50,
          maxAngle: 160,
          side: ProfileSide.left,
          source: ThresholdSource.calibrated,
          bucketUpdated: true,
          rejectedOutlier: false,
        ).toCurlRepRecord(),
        isNull,
        reason: 'view missing',
      );
      expect(
        RepRow(
          repIndex: 1,
          maxAngle: 160,
          side: ProfileSide.left,
          view: CurlCameraView.front,
          source: ThresholdSource.calibrated,
          bucketUpdated: true,
          rejectedOutlier: false,
        ).toCurlRepRecord(),
        isNull,
        reason: 'minAngle missing',
      );
      expect(
        RepRow(
          repIndex: 1,
          minAngle: 50,
          maxAngle: 160,
          side: ProfileSide.left,
          view: CurlCameraView.front,
          bucketUpdated: true,
          rejectedOutlier: false,
        ).toCurlRepRecord(),
        isNull,
        reason: 'source missing',
      );
    });

    test('maps populated row to CurlRepRecord with matching fields', () {
      final row = RepRow(
        repIndex: 3,
        quality: 0.92,
        minAngle: 48.5,
        maxAngle: 162.0,
        side: ProfileSide.right,
        view: CurlCameraView.sideRight,
        source: ThresholdSource.warmup,
        bucketUpdated: true,
        rejectedOutlier: false,
      );

      final record = row.toCurlRepRecord()!;

      expect(record.repIndex, 3);
      expect(record.side, ProfileSide.right);
      expect(record.view, CurlCameraView.sideRight);
      expect(record.minAngle, 48.5);
      expect(record.maxAngle, 162.0);
      expect(record.source, ThresholdSource.warmup);
      expect(record.bucketUpdated, isTrue);
      expect(record.rejectedOutlier, isFalse);
    });

    test('squat-shaped row (only repIndex + quality) returns null', () {
      final row = RepRow(repIndex: 2, quality: 0.75);
      expect(row.toCurlRepRecord(), isNull);
    });
  });
}
