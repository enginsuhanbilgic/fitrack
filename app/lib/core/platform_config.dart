import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;

/// Centralizes every iOS/Android divergence point in the codebase.
///
/// Replaces four scattered `Platform.isAndroid` / `Platform.isIOS` branches
/// in: camera service, ML Kit service, workout screen (mirror), TTS service.
///
/// Singleton so callers share a cheap `PlatformConfig.instance` reference;
/// override for tests via [setTestOverride].
class PlatformConfig {
  static PlatformConfig _instance = PlatformConfig._default();
  static PlatformConfig get instance => _instance;

  /// Test-only hook. Pass null to restore the real platform config.
  static void setTestOverride(PlatformConfig? override) {
    _instance = override ?? PlatformConfig._default();
  }

  PlatformConfig._default();

  /// Camera pixel format for the image stream.
  /// Android: NV21 single plane; iOS: yuv420 three planes.
  ImageFormatGroup get cameraImageFormat =>
      Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.yuv420;

  /// ML Kit input format matching [cameraImageFormat].
  mlkit.InputImageFormat get mlkitInputFormat => Platform.isAndroid
      ? mlkit.InputImageFormat.nv21
      : mlkit.InputImageFormat.yuv420;

  /// Whether the front-camera preview needs horizontal mirroring.
  /// iOS already mirrors selfie coordinates; Android returns raw sensor coords.
  bool frontCameraNeedsMirror({required bool isFrontCamera}) =>
      isFrontCamera && !Platform.isIOS;

  /// iOS-only TTS configuration hook. No-op on Android.
  /// Required so TTS can play alongside the camera stream on iOS.
  Future<void> configureTtsAudioSession(FlutterTts tts) async {
    if (!Platform.isIOS) return;
    await tts
        .setIosAudioCategory(IosTextToSpeechAudioCategory.playAndRecord, const [
          IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
        ]);
  }
}
