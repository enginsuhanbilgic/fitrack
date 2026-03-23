package com.messi.fitrackbenchmark.util

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.YuvImage
import androidx.camera.core.ImageProxy
import java.io.ByteArrayOutputStream

object BitmapUtils {
    fun imageProxyToUprightBitmap(imageProxy: ImageProxy): Bitmap {
        val nv21 = yuv420888ToNv21(imageProxy)
        val yuvImage = YuvImage(nv21, ImageFormat.NV21, imageProxy.width, imageProxy.height, null)
        val out = ByteArrayOutputStream()
        yuvImage.compressToJpeg(Rect(0, 0, imageProxy.width, imageProxy.height), 90, out)
        val imageBytes = out.toByteArray()
        val rawBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
        return rotateBitmap(rawBitmap, imageProxy.imageInfo.rotationDegrees.toFloat())
    }

    private fun rotateBitmap(source: Bitmap, rotationDegrees: Float): Bitmap {
        if (rotationDegrees == 0f) return source
        val matrix = Matrix().apply { postRotate(rotationDegrees) }
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    }

    private fun yuv420888ToNv21(image: ImageProxy): ByteArray {
        val yBuffer = image.planes[0].buffer
        val uBuffer = image.planes[1].buffer
        val vBuffer = image.planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        val nv21 = ByteArray(ySize + uSize + vSize)

        yBuffer.get(nv21, 0, ySize)

        val chromaRowStride = image.planes[1].rowStride
        val chromaPixelStride = image.planes[1].pixelStride
        val width = image.width
        val height = image.height
        var outputOffset = ySize

        val uArray = ByteArray(uSize).also { uBuffer.get(it) }
        val vArray = ByteArray(vSize).also { vBuffer.get(it) }

        for (row in 0 until height / 2) {
            for (col in 0 until width / 2) {
                val index = row * chromaRowStride + col * chromaPixelStride
                nv21[outputOffset++] = vArray[index]
                nv21[outputOffset++] = uArray[index]
            }
        }
        return nv21
    }
}
