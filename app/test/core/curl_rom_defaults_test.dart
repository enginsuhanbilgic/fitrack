import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/curl_rom_defaults.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('CurlRomDefaults.forView with sensitivity', () {
    // Front-view defaults removed 2026-05; CurlCameraView.front is now a
    // sentinel-only enum value and `forView` returns null so callers cascade
    // to the next ROM tier.
    test('front view returns null for all sensitivities', () {
      for (final s in FeedbackSensitivity.values) {
        expect(
          // ignore: deprecated_member_use
          CurlRomDefaults.forView(CurlCameraView.front, s),
          isNull,
          reason:
              'front is a legacy sentinel — forView should cascade (null) for $s',
        );
      }
    });

    test('sideLeft returns derived overrides for high and medium', () {
      final high = CurlRomDefaults.forView(
        CurlCameraView.sideLeft,
        FeedbackSensitivity.high,
      );
      final med = CurlRomDefaults.forView(
        CurlCameraView.sideLeft,
        FeedbackSensitivity.medium,
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
        final leftHigh = CurlRomDefaults.forView(
          CurlCameraView.sideLeft,
          FeedbackSensitivity.high,
        )!;
        final rightHigh = CurlRomDefaults.forView(
          CurlCameraView.sideRight,
          FeedbackSensitivity.high,
        )!;
        final leftMed = CurlRomDefaults.forView(
          CurlCameraView.sideLeft,
          FeedbackSensitivity.medium,
        )!;
        final rightMed = CurlRomDefaults.forView(
          CurlCameraView.sideRight,
          FeedbackSensitivity.medium,
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
          for (final s in FeedbackSensitivity.values) {
            final t = CurlRomDefaults.forView(view, s);
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
      for (final s in FeedbackSensitivity.values) {
        expect(
          CurlRomDefaults.forView(CurlCameraView.unknown, s),
          isNull,
          reason: 'unknown view should return null for $s',
        );
      }
    });
  });
}
