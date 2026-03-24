import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Converts a CameraImage (YUV420/NV21) to NV21 bytes for ML Kit.
/// Handles the interleaved UV planes found on Android Emulators.
Uint8List cameraImageToNv21(CameraImage image) {
  // If the image is already packed into a single NV21 plane, return it directly.
  if (image.planes.length == 1) {
    return image.planes[0].bytes;
  }

  final int width = image.width;
  final int height = image.height;
  final int ySize = width * height;
  final int uvSize = width * height ~/ 2;

  final nv21 = Uint8List(ySize + uvSize);

  // Y Plane
  final yPlane = image.planes[0];
  final yBytes = yPlane.bytes;
  final yStride = yPlane.bytesPerRow;
  
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      nv21[y * width + x] = yBytes[y * yStride + x];
    }
  }

  // UV Planes (Interleave V and U for NV21)
  // On most Android devices, planes[1] is U and planes[2] is V.
  // NV21 expects the V plane then U plane interleaved: V, U, V, U...
  final uPlane = image.planes[1];
  final vPlane = image.planes[2];
  final uBytes = uPlane.bytes;
  final vBytes = vPlane.bytes;
  final uvStride = uPlane.bytesPerRow;
  final uvPixelStride = uPlane.bytesPerPixel ?? 1;

  for (int y = 0; y < height / 2; y++) {
    for (int x = 0; x < width / 2; x++) {
      final int dstIdx = ySize + (y * width) + (x * 2);
      final int srcIdx = (y * uvStride) + (x * uvPixelStride);
      
      if (srcIdx < vBytes.length && srcIdx < uBytes.length) {
        nv21[dstIdx] = vBytes[srcIdx];     // V
        nv21[dstIdx + 1] = uBytes[srcIdx]; // U
      }
    }
  }

  return nv21;
}

/// Converts a CameraImage (YUV420) to RGB bytes resized to [targetW x targetH].
/// Handles rotation (0, 90, 270) and an optional [roi] (Region of Interest) for cropping.
/// [roi] is expected as [left, top, width, height] in normalized coordinates (0.0 to 1.0).
/// When [letterbox] is true, the frame is padded to square before resizing so that
/// landmark coordinates map back to the original frame without aspect-ratio distortion.
Uint8List cameraImageToRgb(CameraImage image, int targetW, int targetH, int rotation, {List<double>? roi, bool letterbox = false}) {
  final int srcW = image.width;
  final int srcH = image.height;

  final bool isSinglePlane = image.planes.length == 1;
  final yBytes = image.planes[0].bytes;
  final uBytes = isSinglePlane ? yBytes : image.planes[1].bytes;
  final vBytes = isSinglePlane ? yBytes : image.planes[2].bytes;

  final int yRowStride = image.planes[0].bytesPerRow;
  final int uvRowStride = isSinglePlane ? srcW : image.planes[1].bytesPerRow;
  final int uvPixelStride = isSinglePlane ? 2 : (image.planes[1].bytesPerPixel ?? 1);
  final int uvOffset = isSinglePlane ? srcW * srcH : 0;

  final rgb = Uint8List(targetW * targetH * 3); // zero-filled = black padding

  // For letterbox mode, treat the source as a square canvas with black padding.
  // Rotations 90/270 swap width and height for the logical frame.
  final bool isRotated = rotation == 90 || rotation == 270;
  final int logicalW = isRotated ? srcH : srcW;
  final int logicalH = isRotated ? srcW : srcH;
  final int sqSize = letterbox ? (logicalW > logicalH ? logicalW : logicalH) : 0;
  final int padX = letterbox ? (sqSize - logicalW) ~/ 2 : 0;
  final int padY = letterbox ? (sqSize - logicalH) ~/ 2 : 0;

  // Define crop boundaries in source pixels (ignored when letterbox is true)
  final double cropX = (!letterbox && roi != null) ? roi[0] * srcW : 0;
  final double cropY = (!letterbox && roi != null) ? roi[1] * srcH : 0;
  final double cropW = (!letterbox && roi != null) ? roi[2] * srcW : srcW.toDouble();
  final double cropH = (!letterbox && roi != null) ? roi[3] * srcH : srcH.toDouble();

  for (int ty = 0; ty < targetH; ty++) {
    for (int tx = 0; tx < targetW; tx++) {
      int sx, sy;

      if (letterbox) {
        // Map target pixel into the square canvas, then subtract padding to get source pixel
        final int sqX = (tx / targetW * sqSize).round();
        final int sqY = (ty / targetH * sqSize).round();
        final int lx = sqX - padX; // logical x in the (possibly-rotated) frame
        final int ly = sqY - padY; // logical y

        if (lx < 0 || lx >= logicalW || ly < 0 || ly >= logicalH) continue; // black

        if (rotation == 90) {
          sx = srcW - 1 - ly;
          sy = lx;
        } else if (rotation == 270) {
          sx = ly;
          sy = srcH - 1 - lx;
        } else {
          sx = lx;
          sy = ly;
        }
      } else {
        // Scale from target to crop area
        final double relativeX = tx / targetW;
        final double relativeY = ty / targetH;

        if (rotation == 90) {
          sx = (cropX + cropW - 1 - (relativeY * cropW)).round();
          sy = (cropY + (relativeX * cropH)).round();
        } else if (rotation == 270) {
          sx = (cropX + (relativeY * cropW)).round();
          sy = (cropY + cropH - 1 - (relativeX * cropH)).round();
        } else {
          sx = (cropX + (relativeX * cropW)).round();
          sy = (cropY + (relativeY * cropH)).round();
        }
      }

      // Clamp to source dimensions
      sx = sx.clamp(0, srcW - 1);
      sy = sy.clamp(0, srcH - 1);

      final int yIndex = sy * yRowStride + sx;
      final int uvIndex = uvOffset + (sy ~/ 2) * uvRowStride + (sx ~/ 2) * uvPixelStride;

      if (yIndex >= yBytes.length || uvIndex >= uBytes.length || uvIndex >= vBytes.length) {
        continue;
      }

      final int y = yBytes[yIndex];
      final int v = vBytes[uvIndex];
      final int u = isSinglePlane ? uBytes[uvIndex + 1] : uBytes[uvIndex];

      int r = (y + 1.370705 * (v - 128)).round().clamp(0, 255);
      int g = (y - 0.337633 * (u - 128) - 0.698001 * (v - 128)).round().clamp(0, 255);
      int b = (y + 1.732446 * (u - 128)).round().clamp(0, 255);

      final int offset = (ty * targetW + tx) * 3;
      rgb[offset] = r;
      rgb[offset + 1] = g;
      rgb[offset + 2] = b;
    }
  }

  return rgb;
}

/// Converts RGBA8888 bytes to RGB bytes resized to [targetW x targetH] with letterboxing.
/// Pads the shorter dimension with black so the content is not distorted when the
/// source is not square. Landmark coordinates produced by inference on this output
/// map correctly back to the original frame's normalized coordinate space.
Uint8List argbToRgbLetterboxed(Uint8List rgba, int srcW, int srcH, int targetW, int targetH) {
  final rgb = Uint8List(targetW * targetH * 3); // zero-filled = black padding

  // Letterbox: fit src into a square of side = max(srcW, srcH)
  final int sqSize = srcW > srcH ? srcW : srcH;
  final int padX = (sqSize - srcW) ~/ 2;
  final int padY = (sqSize - srcH) ~/ 2;

  for (int ty = 0; ty < targetH; ty++) {
    final double relY = ty / targetH;
    final int sqY = (relY * sqSize).round();
    final int sy = sqY - padY;

    for (int tx = 0; tx < targetW; tx++) {
      final double relX = tx / targetW;
      final int sqX = (relX * sqSize).round();
      final int sx = sqX - padX;

      if (sx < 0 || sx >= srcW || sy < 0 || sy >= srcH) continue; // black padding

      final int srcIdx = (sy * srcW + sx) * 4;
      final int dstIdx = (ty * targetW + tx) * 3;

      if (srcIdx + 2 < rgba.length) {
        rgb[dstIdx]     = rgba[srcIdx];
        rgb[dstIdx + 1] = rgba[srcIdx + 1];
        rgb[dstIdx + 2] = rgba[srcIdx + 2];
      }
    }
  }

  return rgb;
}

/// Converts RGBA8888 bytes (from Android Bitmap) to RGB bytes resized to target dimensions.
/// Supports an optional [roi] [left, top, width, height] for cropping.
Uint8List argbToRgb(Uint8List rgba, int srcW, int srcH, int targetW, int targetH, {List<double>? roi}) {
  final rgb = Uint8List(targetW * targetH * 3);

  final double cropX = roi != null ? roi[0] * srcW : 0;
  final double cropY = roi != null ? roi[1] * srcH : 0;
  final double cropW = roi != null ? roi[2] * srcW : srcW.toDouble();
  final double cropH = roi != null ? roi[3] * srcH : srcH.toDouble();

  for (int ty = 0; ty < targetH; ty++) {
    final double relativeY = ty / targetH;
    final int sy = (cropY + relativeY * cropH).round().clamp(0, srcH - 1);
    
    for (int tx = 0; tx < targetW; tx++) {
      final double relativeX = tx / targetW;
      final int sx = (cropX + relativeX * cropW).round().clamp(0, srcW - 1);
      
      final int srcIdx = (sy * srcW + sx) * 4;
      final int dstIdx = (ty * targetW + tx) * 3;

      if (srcIdx + 2 < rgba.length) {
        rgb[dstIdx] = rgba[srcIdx];     // R
        rgb[dstIdx + 1] = rgba[srcIdx + 1]; // G
        rgb[dstIdx + 2] = rgba[srcIdx + 2]; // B
      }
    }
  }

  return rgb;
}

