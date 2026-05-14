import 'package:flutter_test/flutter_test.dart';
import 'package:fitrack/core/curl_rom_defaults.dart';
import 'package:fitrack/core/types.dart';

/// Post-2026-05-14 contract: [CurlRomDefaults.forView] returns the
/// **High-anchored** tuple. Sensitivity is applied as a post-pass on
/// `RomThresholds` (see `rom_thresholds_sensitivity_test.dart` for the
/// full per-tier × per-sensitivity matrix).
void main() {
  group('CurlRomDefaults.forView (High-anchored)', () {
    test('front view returns null (legacy sentinel cascades to next tier)', () {
      // ignore: deprecated_member_use
      expect(CurlRomDefaults.forView(CurlCameraView.front), isNull);
    });

    test('unknown view returns null (no telemetry — cascade to legacy)', () {
      expect(CurlRomDefaults.forView(CurlCameraView.unknown), isNull);
    });

    test('sideLeft returns the High anchor (derived 2026-04-28)', () {
      final anchor = CurlRomDefaults.forView(CurlCameraView.sideLeft);
      expect(anchor, isNotNull);
      expect(anchor!.startAngle, closeTo(162.0, 0.01));
      expect(anchor.peakAngle, closeTo(128.4, 0.01));
      expect(anchor.peakExitAngle, closeTo(143.4, 0.01));
      expect(anchor.endAngle, closeTo(148.4, 0.01));
    });

    test('sideRight matches sideLeft (bilateral symmetry)', () {
      final left = CurlRomDefaults.forView(CurlCameraView.sideLeft)!;
      final right = CurlRomDefaults.forView(CurlCameraView.sideRight)!;
      expect(right.startAngle, left.startAngle);
      expect(right.peakAngle, left.peakAngle);
      expect(right.peakExitAngle, left.peakExitAngle);
      expect(right.endAngle, left.endAngle);
    });

    test('FSM invariant holds for every populated view anchor', () {
      for (final view in [CurlCameraView.sideLeft, CurlCameraView.sideRight]) {
        final t = CurlRomDefaults.forView(view);
        if (t == null) continue;
        expect(t.startAngle, greaterThan(t.endAngle), reason: '$view');
        expect(t.endAngle, greaterThan(t.peakExitAngle), reason: '$view');
        expect(t.peakExitAngle, greaterThan(t.peakAngle), reason: '$view');
      }
    });
  });
}
