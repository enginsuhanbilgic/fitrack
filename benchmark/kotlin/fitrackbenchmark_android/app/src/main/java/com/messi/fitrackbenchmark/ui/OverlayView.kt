package com.messi.fitrackbenchmark.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import android.view.View
import com.messi.fitrackbenchmark.model.PoseFrameResult
import com.messi.fitrackbenchmark.model.PoseSchema
import kotlin.math.min

class OverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    init {
        setWillNotDraw(false)
    }

    private val pointPaint = Paint().apply {
        color = Color.CYAN
        style = Paint.Style.FILL
        isAntiAlias = true
    }

    private val linePaint = Paint().apply {
        color = Color.GREEN
        style = Paint.Style.STROKE
        strokeWidth = 8f
        isAntiAlias = true
    }

    private var currentResult: PoseFrameResult? = null
    private var mirrorHorizontally: Boolean = false

    fun updateResult(result: PoseFrameResult?, mirrorHorizontally: Boolean) {
        currentResult = result
        this.mirrorHorizontally = mirrorHorizontally
        invalidate()
    }

    fun clear() {
        currentResult = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val result = currentResult ?: return
        if (result.landmarks.isEmpty()) return

        val sourceWidth = result.imageWidth.toFloat()
        val sourceHeight = result.imageHeight.toFloat()

        val scale = min(width / sourceWidth, height / sourceHeight)
        val drawnWidth = sourceWidth * scale
        val drawnHeight = sourceHeight * scale
        val offsetX = (width - drawnWidth) / 2f
        val offsetY = (height - drawnHeight) / 2f
        val pointRadius = 6f + min(width, height) * 0.008f

        val pointMap = result.landmarks.associateBy { it.name }

        PoseSchema.overlayConnections.forEach { (startName, endName) ->
            val start = pointMap[startName]
            val end = pointMap[endName]
            if (start != null && end != null && start.score >= 0.2f && end.score >= 0.2f) {
                val startX = projectX(start.xNormalized, drawnWidth, offsetX)
                val startY = offsetY + start.yNormalized * drawnHeight
                val endX = projectX(end.xNormalized, drawnWidth, offsetX)
                val endY = offsetY + end.yNormalized * drawnHeight
                canvas.drawLine(startX, startY, endX, endY, linePaint)
            }
        }

        pointMap.values.forEach { point ->
            if (point.score >= 0.2f) {
                val x = projectX(point.xNormalized, drawnWidth, offsetX)
                val y = offsetY + point.yNormalized * drawnHeight
                canvas.drawCircle(x, y, pointRadius, pointPaint)
            }
        }
    }

    private fun projectX(xNormalized: Float, drawnWidth: Float, offsetX: Float): Float {
        val normalized = if (mirrorHorizontally) 1f - xNormalized else xNormalized
        return offsetX + normalized * drawnWidth
    }
}
