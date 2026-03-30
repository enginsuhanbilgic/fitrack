package com.messi.fitrackbenchmark.engine

import android.content.Context
import com.messi.fitrackbenchmark.model.ModelType

object PoseEngineFactory {
    fun create(context: Context, modelType: ModelType): PoseEngine {
        return when (modelType) {
            ModelType.ML_KIT_FAST -> MlKitFastEngine()
            ModelType.ML_KIT_ACCURATE -> MlKitAccurateEngine()
            ModelType.MOVENET_LIGHTNING -> MoveNetEngine(context, modelType, 192)
            ModelType.MOVENET_THUNDER -> MoveNetEngine(context, modelType, 256)
            ModelType.MEDIAPIPE_POSE_LITE -> MediaPipePoseEngine(context)
        }
    }
}
