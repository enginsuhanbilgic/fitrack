package com.messi.fitrackbenchmark.model

enum class ModelType(
    val displayName: String,
    val assetFileName: String? = null,
) {
    ML_KIT_FAST("ML Kit Fast"),
    ML_KIT_ACCURATE("ML Kit Accurate"),
    MOVENET_LIGHTNING("MoveNet Lightning", "movenet_singlepose_lightning_int8_4.tflite"),
    MOVENET_THUNDER("MoveNet Thunder", "movenet_singlepose_thunder_int8_4.tflite"),
    MEDIAPIPE_POSE_LITE("MediaPipe Pose Lite", "pose_landmarker_lite.task");

    override fun toString(): String = displayName
}
