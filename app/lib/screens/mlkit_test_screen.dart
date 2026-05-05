import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart'
    as mlkit;
import '../models/pose_landmark.dart';
import '../services/camera_service.dart';
import '../widgets/skeleton_painter.dart';

class MLKitTestScreen extends StatefulWidget {
  const MLKitTestScreen({super.key});

  @override
  State<MLKitTestScreen> createState() => _MLKitTestScreenState();
}

class _MLKitTestScreenState extends State<MLKitTestScreen> {
  late CameraService _camera;
  late mlkit.PoseDetector _detector;
  bool _isInitialized = false;
  String? _error;
  List<PoseLandmark> _landmarks = [];
  int _frameCount = 0;
  int _detectionCount = 0;
  String _status = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      debugPrint('TEST: Initializing camera...');
      _camera = CameraService();
      await _camera.init();
      debugPrint('TEST: Camera initialized');

      debugPrint('TEST: Initializing ML Kit detector...');
      _detector = mlkit.PoseDetector(
        options: mlkit.PoseDetectorOptions(
          model: mlkit.PoseDetectionModel.base,
          mode: mlkit.PoseDetectionMode.stream,
        ),
      );
      debugPrint('TEST: ML Kit detector initialized');

      _camera.startStream(_onFrame);
      if (mounted) {
        setState(() {
          _isInitialized = true;
          _status = 'Ready - point camera at body';
        });
      }
    } catch (e) {
      debugPrint('TEST ERROR: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _status = 'Error: $e';
        });
      }
    }
  }

  void _onFrame(CameraImage image) {
    _frameCount++;
    if (_frameCount % 3 == 0) {
      _processFrame(image);
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      debugPrint(
        'TEST: Processing frame #$_frameCount (${image.width}x${image.height})',
      );
      debugPrint(
        'TEST: Plane 0: ${image.planes[0].bytes.length} bytes, bytesPerRow=${image.planes[0].bytesPerRow}',
      );

      final sw = Stopwatch()..start();

      // Try using yuv420 format instead (iOS native format is NV12, which is essentially yuv420)
      mlkit.InputImage inputImage;
      try {
        inputImage = mlkit.InputImage.fromBytes(
          bytes: image.planes.first.bytes,
          metadata: mlkit.InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: mlkit.InputImageRotation.rotation90deg,
            format: mlkit.InputImageFormat.yuv420, // Try yuv420 instead of nv21
            bytesPerRow: image.planes.first.bytesPerRow,
          ),
        );
        debugPrint('TEST: InputImage created with yuv420 format');
      } catch (e) {
        debugPrint('TEST: yuv420 failed, trying nv21: $e');
        inputImage = mlkit.InputImage.fromBytes(
          bytes: image.planes.first.bytes,
          metadata: mlkit.InputImageMetadata(
            size: Size(image.width.toDouble(), image.height.toDouble()),
            rotation: mlkit.InputImageRotation.rotation90deg,
            format: mlkit.InputImageFormat.nv21,
            bytesPerRow: image.planes.first.bytesPerRow,
          ),
        );
      }

      final poses = await _detector.processImage(inputImage);
      sw.stop();

      debugPrint(
        'TEST: Detection returned ${poses.length} poses in ${sw.elapsedMilliseconds}ms',
      );

      if (poses.isNotEmpty) {
        _detectionCount++;
        final pose = poses.first;
        debugPrint('TEST: Pose has ${pose.landmarks.length} landmarks');

        final landmarks = <PoseLandmark>[];
        for (final entry in pose.landmarks.entries) {
          final lm = entry.value;
          final typeValue = entry.key.index;

          if (typeValue >= 0 && typeValue <= 32) {
            landmarks.add(
              PoseLandmark(
                type: typeValue,
                x: (lm.x / image.width).clamp(0.0, 1.0),
                y: (lm.y / image.height).clamp(0.0, 1.0),
                confidence: lm.likelihood,
              ),
            );
          }
        }

        if (mounted) {
          setState(() {
            _landmarks = landmarks;
            _status =
                'Detected #$_detectionCount - ${landmarks.length} landmarks - frame #$_frameCount';
          });
        }
      } else {
        if (mounted) {
          setState(() => _status = 'No body detected - frame #$_frameCount');
        }
      }
    } catch (e) {
      debugPrint('TEST ERROR in processFrame: $e');
    }
  }

  @override
  void dispose() {
    _camera.dispose();
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('ML Kit Pose Test')),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : !_isInitialized
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00E676)),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                if (_camera.controller != null)
                  ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _camera.controller!.value.previewSize!.height,
                        height: _camera.controller!.value.previewSize!.width,
                        child: CameraPreview(_camera.controller!),
                      ),
                    ),
                  ),
                if (_landmarks.isNotEmpty)
                  CustomPaint(
                    painter: SkeletonPainter(
                      landmarks: _landmarks,
                      mirror: false,
                    ),
                    size: Size.infinite,
                  ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _status,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Frames: $_frameCount | Detections: $_detectionCount | Landmarks: ${_landmarks.length}',
                          style: const TextStyle(
                            color: Color(0xFF00E676),
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
