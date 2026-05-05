import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;
import 'package:fitrack/core/platform_config.dart';

void main() {
  group('PlatformConfig', () {
    tearDown(() {
      // Restore the real instance after any override test leaks it.
      PlatformConfig.setTestOverride(null);
    });

    test('cameraImageFormat matches current platform', () {
      final format = PlatformConfig.instance.cameraImageFormat;
      if (Platform.isAndroid) {
        expect(format, ImageFormatGroup.nv21);
      } else {
        expect(format, ImageFormatGroup.yuv420);
      }
    });

    test('mlkitInputFormat matches current platform', () {
      final format = PlatformConfig.instance.mlkitInputFormat;
      if (Platform.isAndroid) {
        expect(format, mlkit.InputImageFormat.nv21);
      } else {
        expect(format, mlkit.InputImageFormat.yuv420);
      }
    });

    test('frontCameraNeedsMirror is true only on Android front camera', () {
      final mirrorFront = PlatformConfig.instance.frontCameraNeedsMirror(
        isFrontCamera: true,
      );
      final mirrorBack = PlatformConfig.instance.frontCameraNeedsMirror(
        isFrontCamera: false,
      );

      expect(
        mirrorBack,
        isFalse,
        reason: 'Back camera never needs a display mirror.',
      );

      if (Platform.isIOS) {
        expect(
          mirrorFront,
          isFalse,
          reason:
              'iOS front camera coordinates already match the selfie preview.',
        );
      } else if (Platform.isAndroid) {
        expect(
          mirrorFront,
          isTrue,
          reason: 'Android returns raw sensor coords — display must flip X.',
        );
      }
    });

    test('setTestOverride swaps and restores instance', () {
      final original = PlatformConfig.instance;
      PlatformConfig.setTestOverride(original);
      expect(PlatformConfig.instance, same(original));

      PlatformConfig.setTestOverride(null);
      expect(
        PlatformConfig.instance,
        isNot(same(original)),
        reason: 'setTestOverride(null) installs a fresh default instance.',
      );
    });
  });
}
