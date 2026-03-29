package com.messi.fitrackbenchmark.model

object PoseSchema {
    const val NOSE = "nose"
    const val LEFT_EYE = "left_eye"
    const val RIGHT_EYE = "right_eye"
    const val LEFT_EAR = "left_ear"
    const val RIGHT_EAR = "right_ear"
    const val LEFT_SHOULDER = "left_shoulder"
    const val RIGHT_SHOULDER = "right_shoulder"
    const val LEFT_ELBOW = "left_elbow"
    const val RIGHT_ELBOW = "right_elbow"
    const val LEFT_WRIST = "left_wrist"
    const val RIGHT_WRIST = "right_wrist"
    const val LEFT_HIP = "left_hip"
    const val RIGHT_HIP = "right_hip"
    const val LEFT_KNEE = "left_knee"
    const val RIGHT_KNEE = "right_knee"
    const val LEFT_ANKLE = "left_ankle"
    const val RIGHT_ANKLE = "right_ankle"

    val overlayConnections = listOf(
        LEFT_SHOULDER to RIGHT_SHOULDER,
        LEFT_SHOULDER to LEFT_ELBOW,
        LEFT_ELBOW to LEFT_WRIST,
        RIGHT_SHOULDER to RIGHT_ELBOW,
        RIGHT_ELBOW to RIGHT_WRIST,
        LEFT_SHOULDER to LEFT_HIP,
        RIGHT_SHOULDER to RIGHT_HIP,
        LEFT_HIP to RIGHT_HIP,
        LEFT_HIP to LEFT_KNEE,
        LEFT_KNEE to LEFT_ANKLE,
        RIGHT_HIP to RIGHT_KNEE,
        RIGHT_KNEE to RIGHT_ANKLE,
    )

    val moveNetKeypointOrder = listOf(
        NOSE,
        LEFT_EYE,
        RIGHT_EYE,
        LEFT_EAR,
        RIGHT_EAR,
        LEFT_SHOULDER,
        RIGHT_SHOULDER,
        LEFT_ELBOW,
        RIGHT_ELBOW,
        LEFT_WRIST,
        RIGHT_WRIST,
        LEFT_HIP,
        RIGHT_HIP,
        LEFT_KNEE,
        RIGHT_KNEE,
        LEFT_ANKLE,
        RIGHT_ANKLE,
    )
}
