import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';
import '../engine/benchmark_engine.dart';
import '../models/benchmark_stats.dart';
import '../models/body_frame_31.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import '../services/analytics_service.dart';
import '../services/frame_extractor_service.dart';
import '../services/mlkit_pose_service.dart';
import '../services/movenet_service.dart';
import '../services/pose_estimator_service.dart';
import '../services/yolo_pose_service.dart';
import '../utils/image_converter.dart';
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

    // Prefer front camera for fitness applications, fall back to first
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
    if (_isProcessing || !mounted) return;
    _isProcessing = true;

    _processCameraImage(image).whenComplete(() {
      if (mounted) {
        _isProcessing = false;
      }
    });
  }

  Future<void> _processCameraImage(CameraImage image) async {
    try {
      late final PoseResult result;
      late final BenchmarkStats stats;

      if (_service is MLKitPoseService) {
        // Fast path: pass NV21 directly to ML Kit
        final nv21 = cameraImageToNv21(image);
        final rotation = _cameraController!.description.sensorOrientation;
        final pair = await _engine.runNv21Inference(
          nv21, image.width, image.height, rotation,
        );
        result = pair.$1;
        stats = pair.$2;
      } else {
        // TFLite path: convert to RGB
        final targetSize = _service is MoveNetService ? 192 : 256;
        final rotation = _cameraController!.description.sensorOrientation;
        
        // Smart Cropping: Request the current ROI from the service
        // YOLO uses letterboxing to preserve aspect ratio (no ROI support).
        final roi = _service.currentRoi;
        final bool useLetterbox = _service is YoloPoseService;
        final rgb = cameraImageToRgb(image, targetSize, targetSize, rotation,
            roi: useLetterbox ? null : roi, letterbox: useLetterbox);
        
        final pair = await _engine.runInference(rgb, targetSize, targetSize);
        PoseResult rawResult = pair.$1;
        stats = pair.$2;

        // Map landmarks from ROI-relative to Full-Frame-relative
        final mappedLandmarks = _service.mapToFullFrame(rawResult.landmarks);
        result = PoseResult(
          landmarks: mappedLandmarks, 
          inferenceTime: rawResult.inferenceTime,
        );

        // Update ROI for the NEXT frame based on CURRENT results
        _service.updateRoi(result);
      }

      // Add to Gemini 3.1 Pro Frame Buffer
      if (result.landmarks.isNotEmpty) {
        _frameBuffer.add(result);
        if (_frameBuffer.length > _maxBufferSize) _frameBuffer.removeAt(0);
      }

      // Log frame to Analytics
      _analytics?.logFrame(result, stats);

      if (mounted) {
        final bool isLive = widget.source == InputSource.liveCamera;
        final bool isFront = isLive && _cameraController?.description.lensDirection == CameraLensDirection.front;
        
        // ML Kit already handles rotation internally, and our TFLite pre-processor also rotates pixels.
        // Therefore, we DO NOT rotate coordinates 90 degrees here.
        // We only mirror the X coordinate if using the front camera, as CameraPreview mirrors the video feed.
        final transformed = result.landmarks.map((lm) {
          return PoseLandmark(
            type: lm.type,
            x: isFront ? 1.0 - lm.x : lm.x,
            y: lm.y,
            confidence: lm.confidence,
          );
        }).toList();

        setState(() {
          _landmarks = transformed;
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
      
      // Request a small version of the frame (e.g., 480px height) for massive speedup.
      // This is still high enough for display and perfect for ML models.
      final frame = await extractor.extractFrame(
        _videoPath!, 
        currentPosMs * 1000,
        width: 320, 
        height: 480,
      );
      
      if (frame != null && mounted) {
        final targetSize = _service is MoveNetService ? 192 : 256;
        // YOLO uses letterboxing to preserve aspect ratio; others use ROI smart cropping.
        final bool useLetterbox = _service is YoloPoseService;
        final roi = useLetterbox ? null : _service.currentRoi;
        final rgb = useLetterbox
            ? argbToRgbLetterboxed(frame.argbBytes, frame.width, frame.height, targetSize, targetSize)
            : argbToRgb(frame.argbBytes, frame.width, frame.height, targetSize, targetSize, roi: roi);

        final pair = await _engine.runInference(rgb, targetSize, targetSize);
        final rawResult = pair.$1;
        final stats = pair.$2;

        // Map landmarks from ROI-relative back to full frame
        final mappedLandmarks = _service.mapToFullFrame(rawResult.landmarks);
        final result = PoseResult(
          landmarks: mappedLandmarks,
          inferenceTime: rawResult.inferenceTime,
        );

        // Update ROI for next frame
        _service.updateRoi(result);

        // Log to Analytics
        _analytics?.logFrame(result, stats);

        // Add to Gemini 3.1 Pro Frame Buffer for temporal analysis
        if (result.landmarks.isNotEmpty) {
          _frameBuffer.add(result);
          if (_frameBuffer.length > _maxBufferSize) _frameBuffer.removeAt(0);
        }

        // Decode the small frame for UI display - much faster than full size
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
          setState(() {
            _currentVideoFrame = frameInfo.image;
            _landmarks = result.landmarks;
            _stats = stats;
            _framesProcessed++;
          });
        }
      }
      // Minimal delay to prevent blocking the UI, but allowing maximum throughput
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
        // Camera preview or video placeholder
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

        // Skeleton overlay
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

        // Metrics overlay (top-right)
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
            
            // Finish & Export Session
            IconButton(
              icon: const Icon(Icons.save_alt, color: Colors.greenAccent),
              onPressed: _exportSession,
              tooltip: 'Finish & Export Session',
            ),
            
            // Gemini 3.1 Pro Analysis Trigger
            IconButton(
              icon: const Icon(Icons.psychology_outlined, color: Colors.cyanAccent),
              onPressed: () {
                if (_frameBuffer.isEmpty) return;
                final json = serializeBodySequence(_frameBuffer);
                
                // Show a dialog with the "Fine-Tuned Body 3.1" payload
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
                debugPrint('Gemini 3.1 Pro Payload: $json');
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
            const SizedBox(height: 12),
            const Text(
              'Device Explorer path:\nAndroid › data › <app-package> › files',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
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
