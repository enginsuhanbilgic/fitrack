import 'dart:io';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import 'pose_estimator_service.dart';
import 'dart:math' as math;

class MediaPipeService extends PoseEstimatorService {
  final bool isFull;
  static const int _inputSize = 256;
  static const int _numKeypoints = 33;

  Interpreter? _interpreter;
  List<double>? _roi;

  MediaPipeService({this.isFull = false});

  @override
  String get name => isFull ? 'MediaPipe Full' : 'MediaPipe Lite';

  @override
  int get keypointCount => _numKeypoints;

  @override
  List<double>? get currentRoi => _roi;

  @override
  Future<void> initialize() async {
    final modelPath = isFull
        ? 'assets/models/pose_landmark_full.tflite'
        : 'assets/models/pose_landmark_lite.tflite';

    // Try GPU delegate first — typically 3-5× faster than CPU for conv-heavy
    // models like BlazePose. Uses Metal on iOS, OpenGL ES on Android.
    // Falls back to multi-threaded CPU if the GPU delegate is unavailable.
    Interpreter? interpreter;
    try {
      final gpuOptions = InterpreterOptions()..threads = 4;
      if (Platform.isIOS) {
        gpuOptions.addDelegate(GpuDelegate());
      } else {
        gpuOptions.addDelegate(GpuDelegateV2());
      }
      interpreter = await Interpreter.fromAsset(modelPath, options: gpuOptions);
    } catch (_) {
      // GPU not available — use CPU with max threads
      final cpuOptions = InterpreterOptions()..threads = 4;
      interpreter = await Interpreter.fromAsset(modelPath, options: cpuOptions);
    }

    _interpreter = interpreter;
    _interpreter!.allocateTensors();
    _roi = null;
  }

  @override
  void updateRoi(PoseResult lastResult) {
    if (lastResult.isEmpty) {
      _roi = null;
      return;
    }

    final validKps = lastResult.landmarks.where((l) => l.confidence > 0.3).toList();
    if (validKps.length < 5) {
      _roi = null;
      return;
    }

    double minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0;
    for (final kp in validKps) {
      if (kp.x < minX) minX = kp.x;
      if (kp.x > maxX) maxX = kp.x;
      if (kp.y < minY) minY = kp.y;
      if (kp.y > maxY) maxY = kp.y;
    }

    final double centerX = (minX + maxX) / 2;
    final double centerY = (minY + maxY) / 2;
    final double boxW = maxX - minX;
    final double boxH = maxY - minY;

    double side = (boxW > boxH ? boxW : boxH) * 1.5;
    side = side.clamp(0.2, 1.0);

    double left = centerX - side / 2;
    double top = centerY - side / 2;

    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (left + side > 1.0) left = 1.0 - side;
    if (top + side > 1.0) top = 1.0 - side;

    _roi = [left, top, side, side];
  }

  @override
  Future<PoseResult> processFrame(Uint8List rgbBytes, int width, int height) async {
    if (_interpreter == null) return PoseResult.empty();

    final sw = Stopwatch()..start();

    Object input;
    if (_interpreter!.getInputTensor(0).type == TensorType.float32) {
      // Normalize bytes to [0,1] using a typed view for bulk allocation;
      // avoid element-by-element division by using Float32List.fromList
      // with a pre-computed list — this is still O(n) but avoids repeated
      // dynamic dispatch. The real speedup comes from running this in a
      // background isolate (via compute() in the caller).
      final floatInput = Float32List(_inputSize * _inputSize * 3);
      for (int i = 0, len = rgbBytes.length; i < len; i++) {
        floatInput[i] = rgbBytes[i] * (1.0 / 255.0);
      }
      input = floatInput.reshape([1, _inputSize, _inputSize, 3]);
    } else {
      input = rgbBytes.reshape([1, _inputSize, _inputSize, 3]);
    }

    int landmarksTensorIndex = -1;
    int poseFlagTensorIndex = -1;
    
    final Map<int, Object> outputs = {};
    for (int i = 0; i < _interpreter!.getOutputTensors().length; i++) {
      final shape = _interpreter!.getOutputTensor(i).shape;
      final type = _interpreter!.getOutputTensor(i).type;
      
      // Calculate flat size
      int size = 1;
      for (var dim in shape) {
        size *= dim;
      }
      
      if (shape.length == 2 && shape[1] == 195) landmarksTensorIndex = i;
      if (shape.length == 2 && shape[1] == 1) poseFlagTensorIndex = i;
      
      if (type == TensorType.float32) {
        outputs[i] = Float32List(size).reshape(shape);
      } else {
        outputs[i] = Uint8List(size).reshape(shape);
      }
    }

    if (landmarksTensorIndex == -1) return PoseResult.empty();

    _interpreter!.runForMultipleInputs([input], outputs);

    final landmarksData = (outputs[landmarksTensorIndex] as List<dynamic>)[0] as List<dynamic>;
    
    double poseScore = 1.0;
    if (poseFlagTensorIndex != -1) {
      poseScore = (outputs[poseFlagTensorIndex] as List<dynamic>)[0][0] as double;
    }

    if (poseScore < 0.5) return PoseResult(landmarks: [], inferenceTime: sw.elapsed);

    final landmarks = <PoseLandmark>[];
    for (int i = 0; i < _numKeypoints; i++) {
      final double x = (landmarksData[i * 5] as double) / _inputSize;
      final double y = (landmarksData[i * 5 + 1] as double) / _inputSize;
      final double visibility = landmarksData[i * 5 + 3] as double;
      
      landmarks.add(PoseLandmark(
        type: i,
        x: x.clamp(0.0, 1.0),
        y: y.clamp(0.0, 1.0),
        confidence: _sigmoid(visibility),
      ));
    }

    sw.stop();
    return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
  }

  double _sigmoid(double x) {
    return 1.0 / (1.0 + math.exp(-x));
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}