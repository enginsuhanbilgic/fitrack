/// ML Kit 33-keypoint skeleton connections.
const List<List<int>> mlkitSkeletonConnections = [
  // Face (Eyes and Nose)
  [0, 1], [1, 2], [2, 3], [0, 4], [4, 5], [5, 6],
  // Shoulders
  [11, 12],
  // Left arm
  [11, 13], [13, 15], [15, 17], [15, 19], [15, 21], [17, 19],
  // Right arm
  [12, 14], [14, 16], [16, 18], [16, 20], [16, 22], [18, 20],
  // Torso
  [11, 23], [12, 24],
  // Hips
  [23, 24],
  // Left leg
  [23, 25], [25, 27], [27, 29], [27, 31], [29, 31],
  // Right leg
  [24, 26], [26, 28], [28, 30], [28, 32], [30, 32],
];

/// COCO 17-keypoint skeleton connections.
/// Each pair is [startKeypointIndex, endKeypointIndex].
const List<List<int>> skeletonConnections = [
  // Head
  [0, 1], [0, 2], [1, 3], [2, 4],
  // Shoulders
  [5, 6],
  // Left arm
  [5, 7], [7, 9],
  // Right arm
  [6, 8], [8, 10],
  // Torso
  [5, 11], [6, 12],
  // Hips
  [11, 12],
  // Left leg
  [11, 13], [13, 15],
  // Right leg
  [12, 14], [14, 16],
];

/// COCO-17: connections used for bicep curl tracking only.
/// Includes torso lines (shoulder→hip) as a posture reference — helps
/// spot torso swinging, a common cheat in bicep curls.
const List<List<int>> bicepCurlSkeletonConnections = [
  [5, 6],   // shoulders
  [5, 7], [7, 9],   // left arm
  [6, 8], [8, 10],  // right arm
  [5, 11], [6, 12], // torso (shoulder → hip)
  [11, 12], // waist
];

/// COCO-17: keypoint indices used for bicep curl
const Set<int> bicepCurlKeypoints = {5, 6, 7, 8, 9, 10, 11, 12};

/// ML Kit BlazePose: connections used for bicep curl tracking only.
const List<List<int>> mlkitBicepCurlSkeletonConnections = [
  [11, 12], // shoulders
  [11, 13], [13, 15], // left arm
  [12, 14], [14, 16], // right arm
  [11, 23], [12, 24], // torso (shoulder → hip)
  [23, 24], // waist
];

/// ML Kit BlazePose: keypoint indices used for bicep curl
const Set<int> mlkitBicepCurlKeypoints = {11, 12, 13, 14, 15, 16, 23, 24};

const List<String> keypointNames = [
  'nose', 'left_eye', 'right_eye', 'left_ear', 'right_ear',
  'left_shoulder', 'right_shoulder', 'left_elbow', 'right_elbow',
  'left_wrist', 'right_wrist', 'left_hip', 'right_hip',
  'left_knee', 'right_knee', 'left_ankle', 'right_ankle',
];
