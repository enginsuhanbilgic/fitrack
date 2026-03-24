import 'dart:typed_data';
import 'dart:ui';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import '../models/pose_landmark.dart' as model;
import '../models/pose_result.dart';
import 'pose_estimator_service.dart';

class MLKitPoseService extends PoseEstimatorService {
  final bool useAccurateModel;

  MLKitPoseService({this.useAccurateModel = false});

  late PoseDetector _detector;

  @override
  String get name => useAccurateModel ? 'ML Kit Full' : 'ML Kit Lite';

  @override
  int get keypointCount => 33; // ML Kit provides 33 landmarks

  @override
  Future<void> initialize() async {
    _detector = PoseDetector(
      options: PoseDetectorOptions(
        model: useAccurateModel
            ? PoseDetectionModel.accurate
            : PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );
  }

  @override
  Future<PoseResult> processNv21Frame(
    Uint8List nv21Bytes, int width, int height, int rotation,
  ) async {
    final inputImage = InputImage.fromBytes(
      bytes: nv21Bytes,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: _rotationFromDegrees(rotation),
        format: InputImageFormat.nv21,
        bytesPerRow: width,
      ),
    );

    return _processInputImage(inputImage, width, height);
  }

  @override
  Future<PoseResult> processFrame(Uint8List bytes, int width, int height) async {
    // For video frames (RGBA) or TFLite RGB frames.
    // If length is width * height * 4, it's RGBA.
    // If length is width * height * 3, it's RGB (which ML Kit doesn't support directly via bytes).
    
    final bool isRgba = bytes.length == width * height * 4;
    
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(width.toDouble(), height.toDouble()),
        rotation: InputImageRotation.rotation0deg,
        format: isRgba ? InputImageFormat.bgra8888 : InputImageFormat.nv21,
        bytesPerRow: isRgba ? width * 4 : width,
      ),
    );

    return _processInputImage(inputImage, width, height);
  }

  Future<PoseResult> _processInputImage(InputImage inputImage, int width, int height) async {
    final sw = Stopwatch()..start();
    try {
      final poses = await _detector.processImage(inputImage);
      sw.stop();

      if (poses.isEmpty) {
        return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
      }

      final pose = poses.first;
      
      // ML Kit processes the image assuming it was rotated back to 0 degrees.
      // Therefore, if the original metadata specified a 90/270 rotation, 
      // the resulting coordinate space has width and height swapped.
      final isRotated = inputImage.metadata?.rotation == InputImageRotation.rotation90deg || 
                        inputImage.metadata?.rotation == InputImageRotation.rotation270deg;
      final double outWidth = isRotated ? height.toDouble() : width.toDouble();
      final double outHeight = isRotated ? width.toDouble() : height.toDouble();

      final landmarks = pose.landmarks.entries.map((entry) {
        final lm = entry.value;
        return model.PoseLandmark(
          type: lm.type.index,
          x: lm.x / outWidth,
          y: lm.y / outHeight,
          confidence: lm.likelihood,
        );
      }).toList();

      return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
    } catch (e) {
      return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
    }
  }

  InputImageRotation _rotationFromDegrees(int degrees) {
    switch (degrees) {
      case 0:
        return InputImageRotation.rotation0deg;
      case 90:
        return InputImageRotation.rotation90deg;
      case 180:
        return InputImageRotation.rotation180deg;
      case 270:
        return InputImageRotation.rotation270deg;
      default:
        return InputImageRotation.rotation0deg;
    }
  }

  @override
  void dispose() {
    _detector.close();
  }
}
