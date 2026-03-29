package com.messi.fitrackbenchmark.engine

import android.graphics.Bitmap
import android.os.SystemClock
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.accurate.AccuratePoseDetectorOptions
import com.messi.fitrackbenchmark.model.ModelType
import com.messi.fitrackbenchmark.model.PoseFrameResult
import com.messi.fitrackbenchmark.model.PosePoint
import com.messi.fitrackbenchmark.model.PoseSchema

class MlKitAccurateEngine : PoseEngine {
    override val modelType: ModelType = ModelType.ML_KIT_ACCURATE

    private val detector = PoseDetection.getClient(
        AccuratePoseDetectorOptions.Builder()
            .setDetectorMode(AccuratePoseDetectorOptions.STREAM_MODE)
            .build(),
    )

    override fun process(
        bitmap: Bitmap,
        frameTimestampMs: Long,
        onResult: (PoseFrameResult) -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        val start = SystemClock.uptimeMillis()
        val image = InputImage.fromBitmap(bitmap, 0)

        detector.process(image)
            .addOnSuccessListener { pose ->
                val points = listOf(
                    PoseSchema.NOSE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.NOSE),
                    PoseSchema.LEFT_EYE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_EYE_INNER),
                    PoseSchema.RIGHT_EYE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_EYE_INNER),
                    PoseSchema.LEFT_EAR to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_EAR),
                    PoseSchema.RIGHT_EAR to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_EAR),
                    PoseSchema.LEFT_SHOULDER to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_SHOULDER),
                    PoseSchema.RIGHT_SHOULDER to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_SHOULDER),
                    PoseSchema.LEFT_ELBOW to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_ELBOW),
                    PoseSchema.RIGHT_ELBOW to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_ELBOW),
                    PoseSchema.LEFT_WRIST to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_WRIST),
                    PoseSchema.RIGHT_WRIST to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_WRIST),
                    PoseSchema.LEFT_HIP to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_HIP),
                    PoseSchema.RIGHT_HIP to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_HIP),
                    PoseSchema.LEFT_KNEE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_KNEE),
                    PoseSchema.RIGHT_KNEE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_KNEE),
                    PoseSchema.LEFT_ANKLE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.LEFT_ANKLE),
                    PoseSchema.RIGHT_ANKLE to pose.getPoseLandmark(com.google.mlkit.vision.pose.PoseLandmark.RIGHT_ANKLE),
                ).mapNotNull { (name, landmark) ->
                    landmark?.let {
                        PosePoint(
                            name = name,
                            xNormalized = it.position.x / bitmap.width.toFloat(),
                            yNormalized = it.position.y / bitmap.height.toFloat(),
                            score = it.inFrameLikelihood,
                        )
                    }
                }

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
            }
            .addOnFailureListener(onError)
    }

    override fun close() {
        detector.close()
    }
}
