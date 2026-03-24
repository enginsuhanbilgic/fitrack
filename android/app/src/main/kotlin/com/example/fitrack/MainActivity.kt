package com.example.fitrack

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private val CHANNEL = "fitrack/video_frames"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "extractFrame" -> {
                    val path = call.argument<String>("path")
                    val timeUs = call.argument<Number>("timeUs")?.toLong()
                    val width = call.argument<Int>("width") ?: -1
                    val height = call.argument<Int>("height") ?: -1

                    if (path == null || timeUs == null) {
                        result.error("INVALID_ARGS", "Missing path or timeUs", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val retriever = MediaMetadataRetriever()
                        if (path.startsWith("content://")) {
                            retriever.setDataSource(this, android.net.Uri.parse(path))
                        } else {
                            retriever.setDataSource(path)
                        }
                        
                        val bitmap = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O_MR1 && width > 0 && height > 0) {
                            retriever.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, width, height)
                        } else {
                            retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
                        }
                        retriever.release()

                        if (bitmap == null) {
                            result.error("NO_FRAME", "Could not extract frame", null)
                            return@setMethodCallHandler
                        }

                        val buffer = ByteBuffer.allocate(bitmap.byteCount)
                        bitmap.copyPixelsToBuffer(buffer)

                        // Convert ARGB to RGBA: bitmap outputs [A, R, G, B] but Dart expects [R, G, B, A]
                        val bytes = buffer.array()
                        val pixelCount = bitmap.width * bitmap.height
                        for (i in 0 until pixelCount) {
                            val offset = i * 4
                            val a = bytes[offset]
                            val r = bytes[offset + 1]
                            val g = bytes[offset + 2]
                            val b = bytes[offset + 3]
                            bytes[offset] = r
                            bytes[offset + 1] = g
                            bytes[offset + 2] = b
                            bytes[offset + 3] = a
                        }

                        val response = mapOf(
                            "bytes" to bytes,
                            "width" to bitmap.width,
                            "height" to bitmap.height
                        )
                        bitmap.recycle()
                        result.success(response)
                    } catch (e: Exception) {
                        result.error("EXTRACT_ERROR", e.message, null)
                    }
                }

                "getVideoDuration" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "Missing path", null)
                        return@setMethodCallHandler
                    }

                    try {
                        val retriever = MediaMetadataRetriever()
                        if (path.startsWith("content://")) {
                            retriever.setDataSource(this, android.net.Uri.parse(path))
                        } else {
                            retriever.setDataSource(path)
                        }
                        val durationMs = retriever.extractMetadata(
                            MediaMetadataRetriever.METADATA_KEY_DURATION
                        )?.toLongOrNull() ?: 0L
                        retriever.release()

                        result.success(durationMs * 1000)
                    } catch (e: Exception) {
                        result.error("DURATION_ERROR", e.message, null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
