package com.messi.fitrackbenchmark.engine

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import com.messi.fitrackbenchmark.model.ModelType
import com.messi.fitrackbenchmark.model.PoseFrameResult
import com.messi.fitrackbenchmark.model.PosePoint
import com.messi.fitrackbenchmark.model.PoseSchema
import org.tensorflow.lite.Interpreter
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MoveNetEngine(
    context: Context,
    override val modelType: ModelType,
    private val inputSize: Int,
) : PoseEngine {

    private val interpreter: Interpreter = Interpreter(
        context.assets.open(modelType.assetFileName!!).use { input ->
            val bytes = input.readBytes()
            ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).apply {
                put(bytes)
                rewind()
            }
        },
        Interpreter.Options().apply {
            setNumThreads(4)
        },
    )

    override fun process(
        bitmap: Bitmap,
        frameTimestampMs: Long,
        onResult: (PoseFrameResult) -> Unit,
        onError: (Throwable) -> Unit,
    ) {
        try {
            val start = SystemClock.uptimeMillis()
            val scaled = Bitmap.createScaledBitmap(bitmap, inputSize, inputSize, true)
            val input = bitmapToModelInput(scaled)
            val output = Array(1) { Array(1) { Array(17) { FloatArray(3) } } }

            interpreter.run(input, output)

            val points = PoseSchema.moveNetKeypointOrder.mapIndexed { index, name ->
                val y = output[0][0][index][0]
                val x = output[0][0][index][1]
                val score = output[0][0][index][2]
                PosePoint(
                    name = name,
                    xNormalized = x.coerceIn(0f, 1f),
                    yNormalized = y.coerceIn(0f, 1f),
                    score = score.coerceIn(0f, 1f),
                )
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
        } catch (t: Throwable) {
            onError(t)
        }
    }

    private fun bitmapToModelInput(bitmap: Bitmap): ByteBuffer {
        val input = ByteBuffer.allocateDirect(1 * inputSize * inputSize * 3)
        input.order(ByteOrder.nativeOrder())

        val pixels = IntArray(inputSize * inputSize)
        bitmap.getPixels(pixels, 0, inputSize, 0, 0, inputSize, inputSize)

        pixels.forEach { pixel ->
            input.put(((pixel shr 16) and 0xFF).toByte())
            input.put(((pixel shr 8) and 0xFF).toByte())
            input.put((pixel and 0xFF).toByte())
        }
        input.rewind()
        return input
    }

    override fun close() {
        interpreter.close()
    }
}
