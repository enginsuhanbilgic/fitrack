import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import 'pose_estimator_service.dart';

class MoveNetService extends PoseEstimatorService {
  static const int _inputSize = 192;
  static const int _numKeypoints = 17;
  static const double _minConfidence = 0.1;

  Interpreter? _interpreter;

  @override
  String get name => 'MoveNet Lightning';

  @override
  int get keypointCount => _numKeypoints;

  TensorType _inputType = TensorType.uint8;
  TensorType _outputType = TensorType.float32;
  List<int> _outputShape = [1, 1, 17, 3];

  // Tracking State
  List<double>? _roi; // [left, top, width, height]

  @override
  List<double>? get currentRoi => _roi;

  @override
  Future<void> initialize() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/models/movenet_lightning.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    _interpreter!.allocateTensors();
    _inputType = _interpreter!.getInputTensor(0).type;
    _outputType = _interpreter!.getOutputTensor(0).type;
    _outputShape = _interpreter!.getOutputTensor(0).shape;
    _roi = null; // Start with full frame
  }

  @override
  void updateRoi(PoseResult lastResult) {
    if (lastResult.isEmpty) {
      _roi = null;
      return;
    }

    // Filter keypoints by confidence
    final validKps = lastResult.landmarks.where((l) => l.confidence > _minConfidence).toList();
    if (validKps.length < 5) {
      _roi = null; // Not enough reliable keypoints to track
      return;
    }

    // Determine bounding box of current landmarks
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

    // The crop size should be generous to allow for person movement.
    // MoveNet research suggests 1.5x the larger dimension of the bounding box.
    double side = (boxW > boxH ? boxW : boxH) * 1.5;
    side = side.clamp(0.2, 1.0); // Don't get too small or too large

    // Calculate normalized ROI [l, t, w, h]
    double left = centerX - side / 2;
    double top = centerY - side / 2;

    // Clamp to [0..1] while maintaining square aspect if possible
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
    if (_inputType == TensorType.float32) {
      final floatInput = Float32List(_inputSize * _inputSize * 3);
      for (int i = 0; i < rgbBytes.length; i++) {
        floatInput[i] = rgbBytes[i] / 255.0;
      }
      input = floatInput.reshape([1, _inputSize, _inputSize, 3]);
    } else {
      input = rgbBytes.reshape([1, _inputSize, _inputSize, 3]);
    }

    final int numRows = _outputShape.length > 2 ? _outputShape[1] : 1;
    final int numCols = _outputShape.length > 2 ? _outputShape[2] : _outputShape[1];
    final int numValues = _outputShape.length > 3 ? _outputShape[3] : 3;
    
    Object output;
    if (_outputType == TensorType.float32) {
      output = Float32List(1 * numRows * numCols * numValues).reshape(_outputShape);
    } else {
      output = Uint8List(1 * numRows * numCols * numValues).reshape(_outputShape);
    }

    _interpreter!.run(input, output);
    
    final landmarks = <PoseLandmark>[];
    // Traverse the nested lists from reshape to find the 17x3 data
    final List<dynamic> outList = output as List<dynamic>;
    final List<dynamic> detections = (numRows == 1) ? outList[0][0] : outList[0];

    for (int i = 0; i < _numKeypoints; i++) {
      if (i < detections.length) {
        final List<dynamic> kp = detections[i];
        double y = (kp[0] is double) ? kp[0] : (kp[0] as int).toDouble();
        double x = (kp[1] is double) ? kp[1] : (kp[1] as int).toDouble();
        double s = (kp[2] is double) ? kp[2] : (kp[2] as int).toDouble();

        // Handle quantized output if necessary (though MoveNet is usually float)
        if (_outputType == TensorType.uint8) {
          y /= 255.0;
          x /= 255.0;
          s /= 255.0;
        }

        landmarks.add(PoseLandmark(
          type: i,
          x: x.clamp(0.0, 1.0),
          y: y.clamp(0.0, 1.0),
          confidence: s.clamp(0.0, 1.0),
        ));
      }
    }

    sw.stop();
    return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
  }

  // Remove the old _preprocessFrame as it's no longer needed

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
