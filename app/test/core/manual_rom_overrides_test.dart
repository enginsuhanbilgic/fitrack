import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/manual_rom_overrides.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('ManualRomOverrides.forView with sensitivity', () {
    test('medium returns same as no-arg forView for front', () {
      final noArg = ManualRomOverrides.forView(CurlCameraView.front);
      final medium = ManualRomOverrides.forView(
        CurlCameraView.front,
        CurlSensitivity.medium,
      );
      expect(medium, isNotNull);
      expect(medium!.startAngle, noArg!.startAngle);
      expect(medium.peakAngle, noArg.peakAngle);
      expect(medium.peakExitAngle, noArg.peakExitAngle);
      expect(medium.endAngle, noArg.endAngle);
    });

    test('high returns frontStrict for front view', () {
      final t = ManualRomOverrides.forView(
        CurlCameraView.front,
        CurlSensitivity.high,
      );
      expect(t, isNotNull);
      expect(t!.startAngle, closeTo(153.0, 0.01));
      expect(t.peakAngle, closeTo(25.0, 0.01));
      expect(t.peakExitAngle, closeTo(40.0, 0.01));
      expect(t.endAngle, closeTo(128.0, 0.01));
    });

    test('FSM invariant holds for all front × sensitivity combinations', () {
      for (final s in CurlSensitivity.values) {
        final t = ManualRomOverrides.forView(CurlCameraView.front, s);
        expect(t, isNotNull, reason: 'front override should exist for $s');
        expect(
          t!.startAngle > t.endAngle,
          isTrue,
          reason: 'start > end violated for $s',
        );
        expect(
          t.endAngle > t.peakExitAngle,
          isTrue,
          reason: 'end > peakExit violated for $s',
        );
        expect(
          t.peakExitAngle > t.peakAngle,
          isTrue,
          reason: 'peakExit > peak violated for $s',
        );
      }
    });

    test('high is tighter than medium for front view', () {
      final high = ManualRomOverrides.forView(
        CurlCameraView.front,
        CurlSensitivity.high,
      )!;
      final med = ManualRomOverrides.forView(
        CurlCameraView.front,
        CurlSensitivity.medium,
      )!;
      expect(high.startAngle, greaterThan(med.startAngle));
      expect(high.peakAngle, lessThan(med.peakAngle));
    });

    test('sideLeft returns derived overrides for high and medium', () {
      final high = ManualRomOverrides.forView(
        CurlCameraView.sideLeft,
        CurlSensitivity.high,
      );
      final med = ManualRomOverrides.forView(
        CurlCameraView.sideLeft,
        CurlSensitivity.medium,
      );

      expect(high, isNotNull);
      expect(high!.startAngle, closeTo(162.0, 0.01));
      expect(high.peakAngle, closeTo(128.4, 0.01));
      expect(high.peakExitAngle, closeTo(143.4, 0.01));
      expect(high.endAngle, closeTo(148.4, 0.01));

      expect(med, isNotNull);
      expect(med!.startAngle, closeTo(159.0, 0.01));
      expect(med.peakAngle, closeTo(136.4, 0.01));
      expect(med.peakExitAngle, closeTo(151.4, 0.01));
      expect(med.endAngle, closeTo(156.4, 0.01));
    });

    test(
      'sideRight returns same derived overrides as sideLeft (bilateral symmetry)',
      () {
        final leftHigh = ManualRomOverrides.forView(
          CurlCameraView.sideLeft,
          CurlSensitivity.high,
        )!;
        final rightHigh = ManualRomOverrides.forView(
          CurlCameraView.sideRight,
          CurlSensitivity.high,
        )!;
        final leftMed = ManualRomOverrides.forView(
          CurlCameraView.sideLeft,
          CurlSensitivity.medium,
        )!;
        final rightMed = ManualRomOverrides.forView(
          CurlCameraView.sideRight,
          CurlSensitivity.medium,
        )!;

        expect(rightHigh.startAngle, leftHigh.startAngle);
        expect(rightHigh.peakAngle, leftHigh.peakAngle);
        expect(rightMed.startAngle, leftMed.startAngle);
        expect(rightMed.peakAngle, leftMed.peakAngle);
      },
    );

    test(
      'FSM invariant holds for all populated side × sensitivity combinations',
      () {
        for (final view in [
          CurlCameraView.sideLeft,
          CurlCameraView.sideRight,
        ]) {
          for (final s in CurlSensitivity.values) {
            final t = ManualRomOverrides.forView(view, s);
            if (t == null) continue; // Permissive is intentionally null
            expect(
              t.startAngle > t.endAngle,
              isTrue,
              reason: 'start>end violated for $view/$s',
            );
            expect(
              t.endAngle > t.peakExitAngle,
              isTrue,
              reason: 'end>peakExit violated for $view/$s',
            );
            expect(
              t.peakExitAngle > t.peakAngle,
              isTrue,
              reason: 'peakExit>peak violated for $view/$s',
            );
          }
        }
      },
    );

    test('unknown view returns null for all sensitivities', () {
      for (final s in CurlSensitivity.values) {
        expect(
          ManualRomOverrides.forView(CurlCameraView.unknown, s),
          isNull,
          reason: 'unknown view should return null for $s',
        );
      }
    });
  });
}
