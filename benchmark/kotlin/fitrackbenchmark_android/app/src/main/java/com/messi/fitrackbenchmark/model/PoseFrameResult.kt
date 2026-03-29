package com.messi.fitrackbenchmark.model

data class PoseFrameResult(
    val modelType: ModelType,
    val frameTimestampMs: Long,
    val latencyMs: Long,
    val imageWidth: Int,
    val imageHeight: Int,
    val landmarks: List<PosePoint>,
) {
    fun point(name: String): PosePoint? = landmarks.firstOrNull { it.name == name }
    val hasPose: Boolean get() = landmarks.isNotEmpty()
    val averageConfidence: Float
        get() = if (landmarks.isEmpty()) 0f else landmarks.map { it.score }.average().toFloat()
}
