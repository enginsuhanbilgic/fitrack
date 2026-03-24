import 'package:flutter/services.dart';

class FrameData {
  final Uint8List argbBytes;
  final int width;
  final int height;
  final int timestampUs;

  FrameData({
    required this.argbBytes,
    required this.width,
    required this.height,
    required this.timestampUs,
  });
}

class FrameExtractorService {
  static const _channel = MethodChannel('fitrack/video_frames');

  /// Extract a single frame at the given timestamp (microseconds).
  Future<FrameData?> extractFrame(String videoPath, int timeUs, {int? width, int? height}) async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'extractFrame',
        {
          'path': videoPath, 
          'timeUs': timeUs,
          if (width != null) 'width': width,
          if (height != null) 'height': height,
        },
      );
      if (result == null) return null;

      return FrameData(
        argbBytes: result['bytes'] as Uint8List,
        width: result['width'] as int,
        height: result['height'] as int,
        timestampUs: timeUs,
      );
    } catch (e) {
      return null;
    }
  }

  /// Extract frames from a video at the given FPS rate.
  /// Yields FrameData for each extracted frame.
  Stream<FrameData> extractFrames(String videoPath, {double fps = 5}) async* {
    // Get video duration first
    final durationUs = await _getVideoDuration(videoPath);
    if (durationUs == null || durationUs <= 0) return;

    final intervalUs = (1000000 / fps).round();

    for (int timeUs = 0; timeUs < durationUs; timeUs += intervalUs) {
      final frame = await extractFrame(videoPath, timeUs);
      if (frame != null) {
        yield frame;
      }
    }
  }

  Future<int?> _getVideoDuration(String videoPath) async {
    try {
      final result = await _channel.invokeMethod<int>(
        'getVideoDuration',
        {'path': videoPath},
      );
      return result;
    } catch (e) {
      return null;
    }
  }
}
