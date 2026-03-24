import 'dart:typed_data';
import 'dart:math';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../models/pose_landmark.dart';
import '../models/pose_result.dart';
import 'pose_estimator_service.dart';

class YoloPoseService extends PoseEstimatorService {
  static const int _inputSize = 256;
  static const int _numKeypoints = 17;
  static const double _confidenceThreshold = 0.1;

  Interpreter? _interpreter;
  List<int> _outputShape = [];

  @override
  String get name => 'YOLO26n-Pose';

  @override
  int get keypointCount => _numKeypoints;

  @override
  Future<void> initialize() async {
    _interpreter = await Interpreter.fromAsset(
      'assets/models/yolo26n_pose.tflite',
      options: InterpreterOptions()..threads = 2,
    );
    _interpreter!.allocateTensors();
    _outputShape = _interpreter!.getOutputTensor(0).shape;
  }

  @override
  Future<PoseResult> processFrame(Uint8List rgbBytes, int width, int height) async {
    if (_interpreter == null) return PoseResult.empty();

    final sw = Stopwatch()..start();
    
    // YOLO26 expects float32 [1, 256, 256, 3] normalized to [0, 1]
    final input = Float32List(_inputSize * _inputSize * 3);
    final int copyLen = min(rgbBytes.length, input.length);
    for (int i = 0; i < copyLen; i++) {
      input[i] = rgbBytes[i] / 255.0;
    }

    // YOLO26 TFLite output: [1, 300, 57]
    // 300 NMS-filtered detections, each with 57 values:
    //   [cx, cy, w, h, conf, kp0x, kp0y, kp0c, ..., kp16x, kp16y, kp16c]
    // Detections are sorted by confidence descending.
    final int numDetections = _outputShape[1]; // 300
    final int numValues     = _outputShape[2]; // 57

    final output = Float32List(1 * numDetections * numValues).reshape(_outputShape);

    _interpreter!.run(input.reshape([1, _inputSize, _inputSize, 3]), output);

    final List<dynamic> outData = (output as List<dynamic>)[0]; // shape [300, 57]

    // Find highest-confidence detection
    int bestIdx = -1;
    double bestConf = 0;
    for (int d = 0; d < numDetections; d++) {
      final double conf = _val(outData[d][4]);
      if (conf > _confidenceThreshold && conf > bestConf) {
        bestConf = conf;
        bestIdx = d;
      }
    }

    if (bestIdx == -1) {
      sw.stop();
      return PoseResult(landmarks: [], inferenceTime: sw.elapsed);
    }

    final List<dynamic> det = outData[bestIdx] as List<dynamic>;
    final landmarks = <PoseLandmark>[];
    for (int i = 0; i < _numKeypoints; i++) {
      final int baseIdx = 5 + i * 3;
      if (baseIdx + 2 >= numValues) break;

      // Keypoints are absolute pixel coords in [0, _inputSize]
      final double kpX    = _val(det[baseIdx]);
      final double kpY    = _val(det[baseIdx + 1]);
      final double kpConf = _val(det[baseIdx + 2]);

      landmarks.add(PoseLandmark(
        type: i,
        x: (kpX / _inputSize).clamp(0.0, 1.0),
        y: (kpY / _inputSize).clamp(0.0, 1.0),
        confidence: kpConf.clamp(0.0, 1.0),
      ));
    }

    sw.stop();
    return PoseResult(landmarks: landmarks, inferenceTime: sw.elapsed);
  }

  double _val(dynamic v) {
    if (v is double) return v;
    if (v is int) return v.toDouble();
    return 0.0;
  }

  @override
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}
