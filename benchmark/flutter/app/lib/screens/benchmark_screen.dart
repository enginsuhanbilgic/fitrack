import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../engine/benchmark_engine.dart';
import '../models/benchmark_stats.dart';
import '../models/body_frame_31.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import '../services/analytics_service.dart';
import '../services/frame_extractor_service.dart';
import '../services/mediapipe_service.dart';
import '../services/mlkit_pose_service.dart';
import '../services/movenet_service.dart';
import '../services/pose_estimator_service.dart';
import '../services/yolo_pose_service.dart';
import '../utils/image_converter.dart';
import '../utils/landmark_smoother.dart';
import '../widgets/metrics_overlay.dart';
import '../widgets/skeleton_painter.dart';
import 'home_screen.dart';

class BenchmarkScreen extends StatefulWidget {
  final PoseModel model;
  final InputSource source;
  final ExerciseType exerciseType;

  const BenchmarkScreen({
    super.key,
    required this.model,
    required this.source,
    required this.exerciseType,
  });

  @override
  State<BenchmarkScreen> createState() => _BenchmarkScreenState();
}

class _BenchmarkScreenState extends State<BenchmarkScreen> {
  late PoseEstimatorService _service;
  late BenchmarkEngine _engine;
  AnalyticsService? _analytics;

  // Camera
  CameraController? _cameraController;
  bool _isProcessing = false;
  bool _isInitialized = false;
  String? _error;

  // Results
  List<PoseLandmark> _landmarks = [];
  BenchmarkStats _stats = BenchmarkStats.zero();
  int _framesProcessed = 0;

  // EMA landmark smoother — applied to display landmarks only, not to engine
  // logic, so rep counting / angle calculation always use raw detections.
  final LandmarkSmoother _smoother = LandmarkSmoother(alpha: 0.4);

  // Frame skipping for slow models (MediaPipe).
  // Camera delivers ~30 FPS; MediaPipe runs ~5-10 FPS.
  // Skipping every other camera frame keeps the preview fluid while giving
  // the inference pipeline a frame gap to breathe — targeting ~15 FPS analysis.
  int _frameSkipCounter = 0;
  // Only MediaPipe benefits; fast models (ML Kit, MoveNet) process every frame.
  bool get _shouldSkipFrames => _service is MediaPipeService;

  // Gemini 3.1 Pro Frame Buffer
  final List<PoseResult> _frameBuffer = [];
  static const int _maxBufferSize = 60; // 2 seconds at 30fps

  // Video
  bool _isVideoRunning = false;
  String? _videoPath;
  ui.Image? _currentVideoFrame;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  PoseEstimatorService _createService() {
    switch (widget.model) {
      case PoseModel.mlkit:
        return MLKitPoseService();
      case PoseModel.mlkitFull:
        return MLKitPoseService(useAccurateModel: true);
      case PoseModel.movenet:
        return MoveNetService();
      case PoseModel.yoloPose:
        return YoloPoseService();
      case PoseModel.mediapipeLite:
        return MediaPipeService(isFull: false);
      case PoseModel.mediapipeFull:
        return MediaPipeService(isFull: true);
    }
  }

  Future<void> _initService() async {
    try {
      _service = _createService();
      await _service.initialize();
      _engine = BenchmarkEngine(_service, widget.exerciseType);
      _analytics = AnalyticsService(modelName: _service.name);
      setState(() => _isInitialized = true);

      if (widget.source == InputSource.liveCamera) {
        await _initCamera();
      } else {
        await _pickAndProcessVideo();
      }
    } catch (e) {
      setState(() => _error = 'Init failed: $e');
    }
  }

  // ── Live Camera ──────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _error = 'No cameras available');
      return;
    }

    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _cameraController!.initialize();
    if (!mounted) return;

    _cameraController!.startImageStream(_onCameraFrame);
  }

  void _onCameraFrame(CameraImage image) {
    if (!mounted) return;

    // For slow models, skip every other incoming camera frame so the camera
    // preview stays fluid at 30 FPS while inference targets ~15 FPS.
    if (_shouldSkipFrames) {
      _frameSkipCounter++;
      if (_frameSkipCounter % 2 != 0) return;
    }

    if (_isProcessing) return;
    _isProcessing = true;

    _processCameraImage(image).whenComplete(() {
      if (mounted) _isProcessing = false;
    });
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      late final PoseResult result;
      late final BenchmarkStats stats;

      if (_service is MLKitPoseService) {
        final nv21 = cameraImageToNv21(image);
        final rotation = _cameraController!.description.sensorOrientation;
        final pair = await _engine.runNv21Inference(
          nv21, image.width, image.height, rotation,
        );
        result = pair.$1;
        stats = pair.$2;
      } else {
        final targetSize = _service is MoveNetService ? 192 : 256;
        final rotation = _cameraController!.description.sensorOrientation;

        final roi = _service.currentRoi;
        final bool useLetterbox = _service is YoloPoseService;

        // For rotated cameras (90°/270°), the ROI was computed in the logical
        // (post-rotation) frame space where x→cols and y→rows. But
        // cameraImageToRgb applies the ROI against native sensor dimensions
        // where the axes are swapped. Transform the ROI here so the crop maps
        // to the correct region of the sensor buffer.
        List<double>? roiForConversion = roi;
        if (!useLetterbox && roi != null && (rotation == 90 || rotation == 270)) {
          // Swap x↔y and w↔h axes to match native sensor space.
          roiForConversion = [roi[1], roi[0], roi[3], roi[2]];
        }

        // Offload pixel-by-pixel RGB conversion to a background isolate.
        // CameraImage holds platform-native objects and cannot be sent directly
        // across isolate boundaries — extract raw byte arrays first, then send
        // the plain data structs which are fully isolate-safe.
        final planeDataList = image.planes.map((p) => _PlaneData(
          bytes: Uint8List.fromList(p.bytes),
          bytesPerRow: p.bytesPerRow,
          bytesPerPixel: p.bytesPerPixel,
        )).toList();

        final rgb = await compute(
          _convertRawPlanesToRgb,
          _RawConvertParams(
            planes: planeDataList,
            srcW: image.width,
            srcH: image.height,
            targetW: targetSize,
            targetH: targetSize,
            rotation: rotation,
            roi: useLetterbox ? null : roiForConversion,
            letterbox: useLetterbox,
          ),
        );

        final pair = await _engine.runInference(rgb, targetSize, targetSize);
        PoseResult rawResult = pair.$1;
        stats = pair.$2;

        final mappedLandmarks = _service.mapToFullFrame(rawResult.landmarks);
        result = PoseResult(
          landmarks: mappedLandmarks,
          inferenceTime: rawResult.inferenceTime,
        );

        _service.updateRoi(result);
      }

      if (result.landmarks.isNotEmpty) {
        _frameBuffer.add(result);
        if (_frameBuffer.length > _maxBufferSize) _frameBuffer.removeAt(0);
      }

      _analytics?.logFrame(result, stats);

      if (mounted) {
        final bool isLive = widget.source == InputSource.liveCamera;
        final bool isFront = isLive && _cameraController?.description.lensDirection == CameraLensDirection.front;
        
        final flipped = result.landmarks.map((lm) => PoseLandmark(
          type: lm.type,
          x: isFront ? 1.0 - lm.x : lm.x,
          y: lm.y,
          confidence: lm.confidence,
        )).toList();

        final smoothed = _smoother.smooth(flipped);

        setState(() {
          _landmarks = smoothed;
          _stats = stats;
          _framesProcessed++;
        });
      }
    } catch (e) {
      if (mounted) {
        debugPrint('Inference error: $e');
      }
    }
  }

  // ── Video File ───────────────────────────────────────────

  Future<void> _pickAndProcessVideo() async {
    final picker = ImagePicker();
    final video = await picker.pickVideo(source: ImageSource.gallery);
    if (video == null) {
      setState(() => _error = 'No video selected');
      return;
    }

    _videoPath = video.path;
    _videoController = VideoPlayerController.file(File(_videoPath!));
    await _videoController!.initialize();
    await _videoController!.setLooping(true);
    await _videoController!.play();

    setState(() {
      _isVideoRunning = true;
    });

    _runVideoInferenceLoop();
  }

  Future<void> _runVideoInferenceLoop() async {
    final extractor = FrameExtractorService();
    
    while (_isVideoRunning && mounted) {
      if (!_videoController!.value.isPlaying) {
        await Future.delayed(const Duration(milliseconds: 100));
        continue;
      }

      final int currentPosMs = _videoController!.value.position.inMilliseconds;
      
      final frame = await extractor.extractFrame(
        _videoPath!, 
        currentPosMs * 1000,
        width: 320, 
        height: 480,
      );
      
      if (frame != null && mounted) {
        final targetSize = _service is MoveNetService ? 192 : 256;
        final bool isYolo = _service is YoloPoseService;
        final List<double>? roi = isYolo ? null : _service.currentRoi;
        // Use letterboxing when:
        //  (a) YOLO always uses it, OR
        //  (b) no ROI yet and frame is non-square — avoids stretching
        //      the person and producing distorted landmark coordinates.
        // When an ROI is active it is always square (see updateRoi), so
        // argbToRgb with a square crop is already aspect-ratio correct.
        final bool useLetterbox = isYolo || (roi == null && frame.width != frame.height);
        final rgb = useLetterbox
            ? argbToRgbLetterboxed(frame.argbBytes, frame.width, frame.height, targetSize, targetSize)
            : argbToRgb(frame.argbBytes, frame.width, frame.height, targetSize, targetSize, roi: roi);

        final pair = await _engine.runInference(rgb, targetSize, targetSize);
        final rawResult = pair.$1;
        final stats = pair.$2;

        final mappedLandmarks = _service.mapToFullFrame(rawResult.landmarks);

        // When letterboxing was applied (no ROI, non-square frame), landmarks
        // are in letterboxed-square space. Convert them back to original frame
        // space before calling updateRoi, so the ROI crop on subsequent frames
        // references the correct region of the source image.
        final List<PoseLandmark> frameSpaceLandmarks;
        if (useLetterbox && !isYolo) {
          final int sqSize = frame.width > frame.height ? frame.width : frame.height;
          final double padX = (sqSize - frame.width) / (2.0 * sqSize);
          final double padY = (sqSize - frame.height) / (2.0 * sqSize);
          final double scaleX = sqSize / frame.width.toDouble();
          final double scaleY = sqSize / frame.height.toDouble();
          frameSpaceLandmarks = mappedLandmarks.map((lm) => PoseLandmark(
            type: lm.type,
            x: ((lm.x - padX) * scaleX).clamp(0.0, 1.0),
            y: ((lm.y - padY) * scaleY).clamp(0.0, 1.0),
            confidence: lm.confidence,
          )).toList();
        } else {
          frameSpaceLandmarks = mappedLandmarks;
        }

        final result = PoseResult(
          landmarks: frameSpaceLandmarks,
          inferenceTime: rawResult.inferenceTime,
        );

        _service.updateRoi(result);
        _analytics?.logFrame(result, stats);

        if (result.landmarks.isNotEmpty) {
          _frameBuffer.add(result);
          if (_frameBuffer.length > _maxBufferSize) _frameBuffer.removeAt(0);
        }

        final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(frame.argbBytes);
        final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
          buffer,
          width: frame.width,
          height: frame.height,
          pixelFormat: ui.PixelFormat.rgba8888,
        );
        final ui.Codec codec = await descriptor.instantiateCodec();
        final ui.FrameInfo frameInfo = await codec.getNextFrame();

        if (mounted) {
          final smoothed = _smoother.smooth(result.landmarks);
          setState(() {
            _currentVideoFrame = frameInfo.image;
            _landmarks = smoothed;
            _stats = stats;
            _framesProcessed++;
          });
        }
      }
      await Future.delayed(Duration.zero);
    }
  }

  @override
  void dispose() {
    _isVideoRunning = false;
    _videoController?.dispose();
    _cameraController?.stopImageStream().catchError((_) {});
    _cameraController?.dispose();
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${widget.model.label} — ${widget.exerciseType.label}'),
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
        ),
      );
    }

    if (!_isInitialized) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.cyanAccent),
            SizedBox(height: 16),
            Text('Initializing model...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: _buildPreview()),
        _buildBottomPanel(),
      ],
    );
  }

  Widget _buildPreview() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.source == InputSource.liveCamera && _cameraController != null && _cameraController!.value.isInitialized)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _cameraController!.value.previewSize!.height,
                height: _cameraController!.value.previewSize!.width,
                child: CameraPreview(_cameraController!),
              ),
            ),
          )
        else if (widget.source == InputSource.videoFile)
          ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _currentVideoFrame?.width.toDouble() ?? 1,
                height: _currentVideoFrame?.height.toDouble() ?? 1,
                child: _currentVideoFrame != null ? RawImage(image: _currentVideoFrame) : const SizedBox(),
              ),
            ),
          )
        else
          const ColoredBox(color: Color(0xFF1A1A1A)),

        if (_landmarks.isNotEmpty)
          CustomPaint(
            painter: SkeletonPainter(
              landmarks: _landmarks,
              exerciseType: widget.exerciseType,
              aspectRatio: widget.source == InputSource.videoFile && _currentVideoFrame != null
                  ? _currentVideoFrame!.width / _currentVideoFrame!.height
                  : (_cameraController != null && _cameraController!.value.isInitialized
                      ? (_cameraController!.value.previewSize!.height / _cameraController!.value.previewSize!.width)
                      : (3 / 4)),
            ),
            size: Size.infinite,
          ),

        Positioned(
          top: 8,
          right: 8,
          child: MetricsOverlay(
            modelName: _service.name,
            stats: _stats,
            landmarkCount: _landmarks.length,
            framesProcessed: _framesProcessed,
            exerciseType: widget.exerciseType,
          ),
        ),
      ],
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF1E1E1E),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _statColumn('FPS', _stats.avgFps.toStringAsFixed(1)),
            _statColumn('Latency', '${_stats.latencyMs.toStringAsFixed(1)}ms'),
            _statColumn('Reps', '${_stats.repCount}'),
            _statColumn('Frames', '$_framesProcessed'),
            
            IconButton(
              icon: const Icon(Icons.save_alt, color: Colors.greenAccent),
              onPressed: _exportSession,
              tooltip: 'Finish & Export Session',
            ),
            
            IconButton(
              icon: const Icon(Icons.psychology_outlined, color: Colors.cyanAccent),
              onPressed: () {
                if (_frameBuffer.isEmpty) return;
                final json = serializeBodySequence(_frameBuffer);
                
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Gemini 3.1 Pro Body Frames'),
                    backgroundColor: const Color(0xFF1E1E1E),
                    titleTextStyle: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold),
                    content: SingleChildScrollView(
                      child: Text(
                        json.length > 500 ? '${json.substring(0, 500)}...' : json,
                        style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace'),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
              tooltip: 'Analyze with Gemini 3.1 Pro',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _exportSession() async {
    if (_analytics == null) return;

    final csvPath = await _analytics!.exportCsv();
    final summary = await _analytics!.generateSummary();
    final jsonPath = await _analytics!.exportJson(summary);

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Session Saved', style: TextStyle(color: Colors.greenAccent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Files saved to:', style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            Text(csvPath, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
            const SizedBox(height: 8),
            Text(jsonPath, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK', style: TextStyle(color: Colors.greenAccent)),
          ),
        ],
      ),
    );
  }

  Widget _statColumn(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: const TextStyle(color: Colors.cyanAccent, fontSize: 16, fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
}

// ── Isolate helpers ───────────────────────────────────────
// These must be top-level (not class members) for compute() to send them
// across isolate boundaries.

class _PlaneData {
  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
  const _PlaneData({required this.bytes, required this.bytesPerRow, required this.bytesPerPixel});
}

class _RawConvertParams {
  final List<_PlaneData> planes;
  final int srcW;
  final int srcH;
  final int targetW;
  final int targetH;
  final int rotation;
  final List<double>? roi;
  final bool letterbox;

  const _RawConvertParams({
    required this.planes,
    required this.srcW,
    required this.srcH,
    required this.targetW,
    required this.targetH,
    required this.rotation,
    required this.roi,
    required this.letterbox,
  });
}

Uint8List _convertRawPlanesToRgb(_RawConvertParams p) {
  final int srcW = p.srcW;
  final int srcH = p.srcH;

  final bool isSinglePlane = p.planes.length == 1;
  final yBytes = p.planes[0].bytes;
  final uBytes = isSinglePlane ? yBytes : p.planes[1].bytes;
  final vBytes = isSinglePlane ? yBytes : p.planes[2].bytes;

  final int yRowStride = p.planes[0].bytesPerRow;
  final int uvRowStride = isSinglePlane ? srcW : p.planes[1].bytesPerRow;
  final int uvPixelStride = isSinglePlane ? 2 : (p.planes[1].bytesPerPixel ?? 1);
  final int uvOffset = isSinglePlane ? srcW * srcH : 0;

  final int targetW = p.targetW;
  final int targetH = p.targetH;
  final int rotation = p.rotation;
  final List<double>? roi = p.roi;
  final bool letterbox = p.letterbox;

  final rgb = Uint8List(targetW * targetH * 3);

  final bool isRotated = rotation == 90 || rotation == 270;
  final int logicalW = isRotated ? srcH : srcW;
  final int logicalH = isRotated ? srcW : srcH;
  final int sqSize = letterbox ? (logicalW > logicalH ? logicalW : logicalH) : 0;
  final int padX = letterbox ? (sqSize - logicalW) ~/ 2 : 0;
  final int padY = letterbox ? (sqSize - logicalH) ~/ 2 : 0;

  final double cropX = (!letterbox && roi != null) ? roi[0] * srcW : 0;
  final double cropY = (!letterbox && roi != null) ? roi[1] * srcH : 0;
  final double cropW = (!letterbox && roi != null) ? roi[2] * srcW : srcW.toDouble();
  final double cropH = (!letterbox && roi != null) ? roi[3] * srcH : srcH.toDouble();

  for (int ty = 0; ty < targetH; ty++) {
    for (int tx = 0; tx < targetW; tx++) {
      int sx, sy;

      if (letterbox) {
        final int sqX = (tx / targetW * sqSize).round();
        final int sqY = (ty / targetH * sqSize).round();
        final int lx = sqX - padX;
        final int ly = sqY - padY;

        if (lx < 0 || lx >= logicalW || ly < 0 || ly >= logicalH) continue;

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

      sx = sx.clamp(0, srcW - 1);
      sy = sy.clamp(0, srcH - 1);

      final int yIndex = sy * yRowStride + sx;
      final int uvIndex = uvOffset + (sy ~/ 2) * uvRowStride + (sx ~/ 2) * uvPixelStride;

      if (yIndex >= yBytes.length || uvIndex >= uBytes.length || uvIndex >= vBytes.length) continue;

      final int y = yBytes[yIndex];
      final int v = vBytes[uvIndex];
      final int u = isSinglePlane ? uBytes[uvIndex + 1] : uBytes[uvIndex];

      final int r = (y + 1.370705 * (v - 128)).round().clamp(0, 255);
      final int g = (y - 0.337633 * (u - 128) - 0.698001 * (v - 128)).round().clamp(0, 255);
      final int b = (y + 1.732446 * (u - 128)).round().clamp(0, 255);

      final int offset = (ty * targetW + tx) * 3;
      rgb[offset] = r;
      rgb[offset + 1] = g;
      rgb[offset + 2] = b;
    }
  }

  return rgb;
}
