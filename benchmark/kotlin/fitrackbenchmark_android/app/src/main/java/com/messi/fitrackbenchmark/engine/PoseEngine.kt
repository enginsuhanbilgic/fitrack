package com.messi.fitrackbenchmark.engine

import android.graphics.Bitmap
import com.messi.fitrackbenchmark.model.ModelType
import com.messi.fitrackbenchmark.model.PoseFrameResult
import java.io.Closeable

interface PoseEngine : Closeable {
    val modelType: ModelType

    fun process(
        bitmap: Bitmap,
        frameTimestampMs: Long,
        onResult: (PoseFrameResult) -> Unit,
        onError: (Throwable) -> Unit,
    )
}
