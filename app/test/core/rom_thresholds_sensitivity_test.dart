import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/default_rom_thresholds.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('RomThresholds.global with sensitivity', () {
    // All tests assume kUseManualOverrides = true, kUseDataDrivenThresholds = false
    // (the shipping flag config). Front and side views hit the manual-override
    // tier with per-sensitivity constants (strict/default). Unknown view falls
    // to the legacy tier where _applyRomSensitivity applies high deltas.

    test('medium is identical to no-arg call for front view', () {
      final noArg = RomThresholds.global(CurlCameraView.front);
      final medium = RomThresholds.global(
        CurlCameraView.front,
        CurlSensitivity.medium,
      );
      expect(medium.startAngle, noArg.startAngle);
      expect(medium.peakAngle, noArg.peakAngle);
      expect(medium.peakExitAngle, noArg.peakExitAngle);
      expect(medium.endAngle, noArg.endAngle);
      expect(medium.source, ThresholdSource.global);
    });

    test('high tightens front view via manual tier: start+5, peak-10', () {
      final t = RomThresholds.global(
        CurlCameraView.front,
        CurlSensitivity.high,
      );
      // frontStrict constants from manual_rom_overrides.dart
      expect(t.startAngle, closeTo(153.0, 0.01));
      expect(t.peakAngle, closeTo(25.0, 0.01));
      expect(t.peakExitAngle, closeTo(40.0, 0.01)); // peak + 15
      expect(t.endAngle, closeTo(128.0, 0.01));
      expect(t.source, ThresholdSource.global);
    });

    test('FSM invariant holds for all views x all sensitivities', () {
      for (final view in CurlCameraView.values) {
        for (final s in CurlSensitivity.values) {
          final t = RomThresholds.global(view, s);
          expect(
            t.startAngle > t.endAngle,
            isTrue,
            reason: 'start > end violated for view=$view sensitivity=$s',
          );
          expect(
            t.endAngle > t.peakExitAngle,
            isTrue,
            reason: 'end > peakExit violated for view=$view sensitivity=$s',
          );
          expect(
            t.peakExitAngle > t.peakAngle,
            isTrue,
            reason: 'peakExit > peak violated for view=$view sensitivity=$s',
          );
        }
      }
    });

    test('high on legacy-tier view (unknown): tighter start, lower peak', () {
      final med = RomThresholds.global(
        CurlCameraView.unknown,
        CurlSensitivity.medium,
      );
      final high = RomThresholds.global(
        CurlCameraView.unknown,
        CurlSensitivity.high,
      );

      expect(high.startAngle, closeTo(med.startAngle + 5.0, 0.01));
      expect(high.peakAngle, closeTo(med.peakAngle - 10.0, 0.01));
    });

    test('peakExitAngle always equals peakAngle + kCurlPeakExitGap', () {
      for (final view in CurlCameraView.values) {
        for (final s in CurlSensitivity.values) {
          final t = RomThresholds.global(view, s);
          expect(
            t.peakExitAngle,
            closeTo(t.peakAngle + kCurlPeakExitGap, 0.01),
            reason: 'peakExit != peak+gap for view=$view sensitivity=$s',
          );
        }
      }
    });

    test(
      'high uses sideLeft manual override (derived 2026-04-28 Strict bucket)',
      () {
        // ManualRomOverrides.sideLeftStrict is now populated — the override tier
        // intercepts before any legacy delta is applied, so values come directly
        // from the derived constants, not from med ± fixed deltas.
        final high = RomThresholds.global(
          CurlCameraView.sideLeft,
          CurlSensitivity.high,
        );
        expect(high.startAngle, closeTo(162.0, 0.01));
        expect(high.peakAngle, closeTo(128.4, 0.01));
        expect(high.peakExitAngle, closeTo(143.4, 0.01));
        expect(high.endAngle, closeTo(148.4, 0.01));
        expect(high.source, ThresholdSource.global);
      },
    );

    test(
      'high uses sideRight manual override (bilateral mirror of sideLeft)',
      () {
        final high = RomThresholds.global(
          CurlCameraView.sideRight,
          CurlSensitivity.high,
        );
        expect(high.startAngle, closeTo(162.0, 0.01));
        expect(high.peakAngle, closeTo(128.4, 0.01));
      },
    );

    test('sideLeft medium is identical to no-arg call', () {
      final noArg = RomThresholds.global(CurlCameraView.sideLeft);
      final medium = RomThresholds.global(
        CurlCameraView.sideLeft,
        CurlSensitivity.medium,
      );
      expect(medium.startAngle, noArg.startAngle);
      expect(medium.peakAngle, noArg.peakAngle);
      expect(medium.peakExitAngle, noArg.peakExitAngle);
      expect(medium.endAngle, noArg.endAngle);
    });

    test('sideRight constants are aliases of sideLeft — same value', () {
      expect(
        DefaultRomThresholds.sideRightStartAngle,
        DefaultRomThresholds.sideLeftStartAngle,
      );
      expect(
        DefaultRomThresholds.sideRightPeakAngle,
        DefaultRomThresholds.sideLeftPeakAngle,
      );
      expect(
        DefaultRomThresholds.sideRightPeakExitAngle,
        DefaultRomThresholds.sideLeftPeakExitAngle,
      );
      expect(
        DefaultRomThresholds.sideRightEndAngle,
        DefaultRomThresholds.sideLeftEndAngle,
      );
    });
  });
}
