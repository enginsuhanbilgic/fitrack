/// ML Kit BlazePose 33-landmark indices.
/// See: https://developers.google.com/ml-kit/vision/pose-detection
abstract class LM {
  static const int nose = 0;
  static const int leftEyeInner = 1;
  static const int leftEye = 2;
  static const int leftEyeOuter = 3;
  static const int rightEyeInner = 4;
  static const int rightEye = 5;
  static const int rightEyeOuter = 6;
  static const int leftEar = 7;
  static const int rightEar = 8;
  static const int leftMouth = 9;
  static const int rightMouth = 10;
  static const int leftShoulder = 11;
  static const int rightShoulder = 12;
  static const int leftElbow = 13;
  static const int rightElbow = 14;
  static const int leftWrist = 15;
  static const int rightWrist = 16;
  static const int leftPinky = 17;
  static const int rightPinky = 18;
  static const int leftIndex = 19;
  static const int rightIndex = 20;
  static const int leftThumb = 21;
  static const int rightThumb = 22;
  static const int leftHip = 23;
  static const int rightHip = 24;
  static const int leftKnee = 25;
  static const int rightKnee = 26;
  static const int leftAnkle = 27;
  static const int rightAnkle = 28;
  static const int leftHeel = 29;
  static const int rightHeel = 30;
  static const int leftFootIndex = 31;
  static const int rightFootIndex = 32;

  /// Full skeleton connections.
  static const List<(int, int)> connections = [
    // Torso
    (leftShoulder, rightShoulder),
    (leftHip, rightHip),
    (leftShoulder, leftHip),
    (rightShoulder, rightHip),
    // Left arm
    (leftShoulder, leftElbow),
    (leftElbow, leftWrist),
    // Right arm
    (rightShoulder, rightElbow),
    (rightElbow, rightWrist),
    // Left leg
    (leftHip, leftKnee),
    (leftKnee, leftAnkle),
    // Right leg
    (rightHip, rightKnee),
    (rightKnee, rightAnkle),
  ];

  /// Upper body only — no legs. Used for biceps curl.
  static const List<(int, int)> upperBodyConnections = [
    (leftShoulder, rightShoulder),
    (leftHip, rightHip),
    (leftShoulder, leftHip),
    (rightShoulder, rightHip),
    (leftShoulder, leftElbow),
    (leftElbow, leftWrist),
    (rightShoulder, rightElbow),
    (rightElbow, rightWrist),
  ];

  /// Upper body landmark indices (for filtering joints).
  static const Set<int> upperBodyLandmarks = {
    nose, leftEyeInner, leftEye, leftEyeOuter,
    rightEyeInner, rightEye, rightEyeOuter,
    leftEar, rightEar, leftMouth, rightMouth,
    leftShoulder, rightShoulder, leftElbow, rightElbow,
    leftWrist, rightWrist, leftPinky, rightPinky,
    leftIndex, rightIndex, leftThumb, rightThumb,
    leftHip, rightHip,
  };

  /// Body-only landmarks — excludes face (eyes, ears, mouth) and hands
  /// (pinky, index, thumb). Used to keep the rendering clean and focused
  /// on the large joints.
  static const Set<int> bodyOnlyLandmarks = {
    nose,
    leftShoulder,
    rightShoulder,
    leftElbow,
    rightElbow,
    leftWrist,
    rightWrist,
    leftHip,
    rightHip,
    leftKnee,
    rightKnee,
    leftAnkle,
    rightAnkle,
    leftHeel,
    rightHeel,
    leftFootIndex,
    rightFootIndex,
  };
}
