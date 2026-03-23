package com.messi.fitrackbenchmark.engine

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult
import com.messi.fitrackbenchmark.model.ModelType
import com.messi.fitrackbenchmark.model.PoseFrameResult
import com.messi.fitrackbenchmark.model.PosePoint
import com.messi.fitrackbenchmark.model.PoseSchema

class MediaPipePoseEngine(
    context: Context,
) : PoseEngine {

    override val modelType: ModelType = ModelType.MEDIAPIPE_POSE_LITE

    private val poseLandmarker: PoseLandmarker = PoseLandmarker.createFromOptions(
        context,
        PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setDelegate(Delegate.CPU)
                    .setModelAssetPath(modelType.assetFileName)
                    .build(),
            )
            .setMinPoseDetectionConfidence(0.5f)
            .setMinPosePresenceConfidence(0.5f)
            .setMinTrackingConfidence(0.5f)
            .setRunningMode(RunningMode.VIDEO)
            .build(),
    )

    override fun process(
        bitmap: Bitmap,
        frameTimestampMs: Long,
        onResult: (PoseFrameResult) -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        try {
            val start = SystemClock.uptimeMillis()
            val mpImage = BitmapImageBuilder(bitmap).build()
            val result = poseLandmarker.detectForVideo(mpImage, frameTimestampMs)
            val points = mapResult(result)

            onResult(
                PoseFrameResult(
                    modelType = modelType,
                    frameTimestampMs = frameTimestampMs,
                    latencyMs = SystemClock.uptimeMillis() - start,
                    imageWidth = bitmap.width,
                    imageHeight = bitmap.height,
                    landmarks = points,
                ),
            )
        } catch (t: Throwable) {
            onError(t)
        }
    }

    private fun mapResult(result: PoseLandmarkerResult?): List<PosePoint> {
        val pose = result?.landmarks()?.firstOrNull() ?: return emptyList()
        return listOf(
            PoseSchema.NOSE to pose.getOrNull(0),
            PoseSchema.LEFT_EYE to pose.getOrNull(2),
            PoseSchema.RIGHT_EYE to pose.getOrNull(5),
            PoseSchema.LEFT_EAR to pose.getOrNull(7),
            PoseSchema.RIGHT_EAR to pose.getOrNull(8),
            PoseSchema.LEFT_SHOULDER to pose.getOrNull(11),
            PoseSchema.RIGHT_SHOULDER to pose.getOrNull(12),
            PoseSchema.LEFT_ELBOW to pose.getOrNull(13),
            PoseSchema.RIGHT_ELBOW to pose.getOrNull(14),
            PoseSchema.LEFT_WRIST to pose.getOrNull(15),
            PoseSchema.RIGHT_WRIST to pose.getOrNull(16),
            PoseSchema.LEFT_HIP to pose.getOrNull(23),
            PoseSchema.RIGHT_HIP to pose.getOrNull(24),
            PoseSchema.LEFT_KNEE to pose.getOrNull(25),
            PoseSchema.RIGHT_KNEE to pose.getOrNull(26),
            PoseSchema.LEFT_ANKLE to pose.getOrNull(27),
            PoseSchema.RIGHT_ANKLE to pose.getOrNull(28),
        ).mapNotNull { (name, landmark) -> landmark?.toPosePoint(name) }
    }

    private fun NormalizedLandmark.toPosePoint(name: String): PosePoint {
        val score = try {
            visibility().orElse(1f)
        } catch (_: Throwable) {
            1f
        }
        return PosePoint(
            name = name,
            xNormalized = x(),
            yNormalized = y(),
            score = score.coerceIn(0f, 1f),
        )
    }

    override fun close() {
        poseLandmarker.close()
    }
}
