import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../core/platform_config.dart';

/// Thin wrapper around CameraController.
/// Hides platform details so screens only see [onFrame] callbacks.
class CameraService {
  CameraController? _ctrl;
  bool _streaming = false;

  /// True once the camera is initialised and preview is ready.
  bool get isReady => _ctrl?.value.isInitialized ?? false;

  /// The underlying controller (needed by CameraPreview widget).
  CameraController? get controller => _ctrl;

  /// Sensor rotation in degrees (needed by ML Kit).
  int get sensorRotation => _ctrl?.description.sensorOrientation ?? 0;

  /// Whether the active camera is front-facing.
  bool get isFrontCamera =>
      _ctrl?.description.lensDirection == CameraLensDirection.front;

  /// Initialise the front camera.
  /// Android: NV21 format (single plane)
  /// iOS: yuv420 format (3 planes: Y, U, V)
  Future<void> init() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('No cameras found');

    final front = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _ctrl = CameraController(
      front,
      ResolutionPreset.medium, // 480 × 640 — good balance
      enableAudio: false,
      // Android: NV21 (single plane), iOS: yuv420 (3 planes)
      imageFormatGroup: PlatformConfig.instance.cameraImageFormat,
    );

    await _ctrl!.initialize();
  }

  /// Start streaming frames. [onFrame] delivers the raw CameraImage.
  void startStream(void Function(CameraImage image) onFrame) {
    if (_streaming || _ctrl == null) return;
    _streaming = true;

    int frameCount = 0;
    _ctrl!.startImageStream((CameraImage image) {
      frameCount++;
      if (frameCount % 30 == 0) {
        debugPrint(
          'DEBUG [CameraService]: Frame #$frameCount - ${image.width}x${image.height}, planes: ${image.planes.length}',
        );
      }

      onFrame(image);
    });
  }

  /// Stop the frame stream (keeps preview alive).
  Future<void> stopStream() async {
    if (!_streaming || _ctrl == null) return;
    _streaming = false;
    await _ctrl!.stopImageStream();
  }

  /// Release everything.
  Future<void> dispose() async {
    _streaming = false;
    await _ctrl?.dispose();
    _ctrl = null;
  }
}
