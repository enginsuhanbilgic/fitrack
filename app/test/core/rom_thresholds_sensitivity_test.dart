import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/constants.dart';
import 'package:fitrack/core/pipeline_rom_defaults.dart';
import 'package:fitrack/core/rom_thresholds.dart';
import 'package:fitrack/core/types.dart';

void main() {
  group('RomThresholds.global with sensitivity', () {
    // All tests assume kUseTelemetryRomDefaults = true, kUsePipelineRomDefaults = false
    // (the shipping flag config). Front and side views hit the telemetry-defaults
    // tier with per-sensitivity constants (strict/default). Unknown view falls
    // to the legacy tier where _applyRomSensitivity applies high deltas.

    // Front-view defaults removed 2026-05; CurlCameraView.front is now a
    // legacy sentinel that cascades to side-view fallback thresholds via
    // `PipelineRomDefaults.forView`. RomThresholds.global must still return
    // a valid (invariant-holding) threshold tuple so the FSM doesn't break
    // when the view detector's fallback sentinel reaches a curl session.
    test('front (legacy sentinel) returns invariant-holding thresholds', () {
      // Front view removed 2026-05. The enum value is retained as a view-
      // detector fallback sentinel. The resolver cascades:
      //   CurlRomDefaults.forView(front) → null (sentinel, no telemetry)
      //   PipelineRomDefaults.forView(front) → side-right pipeline values
      // Either way, the FSM must still receive a valid threshold tuple.
      // ignore: deprecated_member_use
      final t = RomThresholds.global(
        // ignore: deprecated_member_use
        CurlCameraView.front,
        FeedbackSensitivity.medium,
      );
      expect(t.startAngle, greaterThan(t.endAngle));
      expect(t.endAngle, greaterThan(t.peakExitAngle));
      expect(t.peakExitAngle, greaterThan(t.peakAngle));
      expect(t.source, ThresholdSource.global);
    });

    test('FSM invariant holds for all views x all sensitivities', () {
      for (final view in CurlCameraView.values) {
        for (final s in FeedbackSensitivity.values) {
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
      // Tier-3 looseness deltas (2026-05-15 retune):
      //   medium = high + (dStart, dPeak, dEnd) = high + (-8, +12, -6)
      // Therefore: high - medium = (+8, -12, +6).
      final med = RomThresholds.global(
        CurlCameraView.unknown,
        FeedbackSensitivity.medium,
      );
      final high = RomThresholds.global(
        CurlCameraView.unknown,
        FeedbackSensitivity.high,
      );

      expect(high.startAngle, closeTo(med.startAngle + 8.0, 0.01));
      expect(high.peakAngle, closeTo(med.peakAngle - 12.0, 0.01));
      expect(high.endAngle, closeTo(med.endAngle + 6.0, 0.01));
    });

    test('peakExitAngle always equals peakAngle + kCurlPeakExitGap', () {
      for (final view in CurlCameraView.values) {
        for (final s in FeedbackSensitivity.values) {
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
      'high uses sideLeft telemetry default (derived 2026-04-28 Strict bucket)',
      () {
        // CurlRomDefaults.sideLeftStrict is now populated — the telemetry tier
        // intercepts before any legacy delta is applied, so values come directly
        // from the derived constants, not from med ± fixed deltas.
        final high = RomThresholds.global(
          CurlCameraView.sideLeft,
          FeedbackSensitivity.high,
        );
        expect(high.startAngle, closeTo(162.0, 0.01));
        expect(high.peakAngle, closeTo(128.4, 0.01));
        expect(high.peakExitAngle, closeTo(143.4, 0.01));
        expect(high.endAngle, closeTo(148.4, 0.01));
        expect(high.source, ThresholdSource.global);
      },
    );

    test(
      'high uses sideRight telemetry default (bilateral mirror of sideLeft)',
      () {
        final high = RomThresholds.global(
          CurlCameraView.sideRight,
          FeedbackSensitivity.high,
        );
        expect(high.startAngle, closeTo(162.0, 0.01));
        expect(high.peakAngle, closeTo(128.4, 0.01));
      },
    );

    test('sideLeft medium is identical to no-arg call', () {
      final noArg = RomThresholds.global(CurlCameraView.sideLeft);
      final medium = RomThresholds.global(
        CurlCameraView.sideLeft,
        FeedbackSensitivity.medium,
      );
      expect(medium.startAngle, noArg.startAngle);
      expect(medium.peakAngle, noArg.peakAngle);
      expect(medium.peakExitAngle, noArg.peakExitAngle);
      expect(medium.endAngle, noArg.endAngle);
    });

    test('sideRight constants are aliases of sideLeft — same value', () {
      expect(
        PipelineRomDefaults.sideRightStartAngle,
        PipelineRomDefaults.sideLeftStartAngle,
      );
      expect(
        PipelineRomDefaults.sideRightPeakAngle,
        PipelineRomDefaults.sideLeftPeakAngle,
      );
      expect(
        PipelineRomDefaults.sideRightPeakExitAngle,
        PipelineRomDefaults.sideLeftPeakExitAngle,
      );
      expect(
        PipelineRomDefaults.sideRightEndAngle,
        PipelineRomDefaults.sideLeftEndAngle,
      );
    });
  });
}
