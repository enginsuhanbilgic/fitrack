package com.messi.fitrackbenchmark.model

import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

data class BenchmarkFrameRecord(
    val relativeTimestampMs: Long,
    val latencyMs: Long,
    val poseFound: Boolean,
    val repCount: Int,
    val stage: String,
    val representativeAngleDeg: Float?,
    val avgConfidence: Float,
    val keypointCount: Int,
    val rollingFps: Double,
)

data class BenchmarkSummary(
    val modelType: ModelType,
    val durationMs: Long,
    val totalFrames: Int,
    val poseFrames: Int,
    val repCount: Int,
    val meanLatencyMs: Double,
    val p50LatencyMs: Double,
    val p95LatencyMs: Double,
    val minLatencyMs: Long,
    val maxLatencyMs: Long,
    val averageFps: Double,
    val deviceManufacturer: String,
    val deviceModel: String,
    val androidVersion: String,
    val startedAtEpochMs: Long,
    val finishedAtEpochMs: Long,
)

data class BenchmarkBundle(
    val summary: BenchmarkSummary,
    val frames: List<BenchmarkFrameRecord>,
)

data class BenchmarkSavedFiles(
    val summaryFile: File,
    val frameCsvFile: File,
)

class BenchmarkRecorder {
    private val frameRecords = mutableListOf<BenchmarkFrameRecord>()
    private var modelType: ModelType? = null
    private var startedAtMs: Long = 0L
    private var finishedAtMs: Long = 0L
    private var latestRepCount: Int = 0

    fun start(selectedModel: ModelType, startedAtMs: Long) {
        modelType = selectedModel
        this.startedAtMs = startedAtMs
        this.finishedAtMs = startedAtMs
        this.latestRepCount = 0
        frameRecords.clear()
    }

    fun record(
        result: PoseFrameResult,
        rollingFps: Double,
        curlSnapshot: CurlSnapshot,
    ) {
        latestRepCount = curlSnapshot.reps
        frameRecords += BenchmarkFrameRecord(
            relativeTimestampMs = result.frameTimestampMs - startedAtMs,
            latencyMs = result.latencyMs,
            poseFound = result.hasPose,
            repCount = curlSnapshot.reps,
            stage = curlSnapshot.stage,
            representativeAngleDeg = curlSnapshot.representativeAngleDeg,
            avgConfidence = result.averageConfidence,
            keypointCount = result.landmarks.size,
            rollingFps = rollingFps,
        )
        finishedAtMs = result.frameTimestampMs
    }

    fun finish(finishedAtMs: Long): BenchmarkBundle {
        this.finishedAtMs = finishedAtMs
        val nonEmptyLatencies = frameRecords.map { it.latencyMs }.sorted()
        val totalFrames = frameRecords.size
        val poseFrames = frameRecords.count { it.poseFound }
        val durationMs = (finishedAtMs - startedAtMs).coerceAtLeast(1L)
        val avgFps = if (durationMs == 0L) 0.0 else totalFrames * 1000.0 / durationMs.toDouble()
        val summary = BenchmarkSummary(
            modelType = requireNotNull(modelType),
            durationMs = durationMs,
            totalFrames = totalFrames,
            poseFrames = poseFrames,
            repCount = latestRepCount,
            meanLatencyMs = nonEmptyLatencies.averageOrZero(),
            p50LatencyMs = nonEmptyLatencies.percentile(50.0),
            p95LatencyMs = nonEmptyLatencies.percentile(95.0),
            minLatencyMs = nonEmptyLatencies.minOrNull() ?: 0L,
            maxLatencyMs = nonEmptyLatencies.maxOrNull() ?: 0L,
            averageFps = avgFps,
            deviceManufacturer = Build.MANUFACTURER.orEmpty(),
            deviceModel = Build.MODEL.orEmpty(),
            androidVersion = Build.VERSION.RELEASE.orEmpty(),
            startedAtEpochMs = startedAtMs,
            finishedAtEpochMs = finishedAtMs,
        )
        return BenchmarkBundle(summary, frameRecords.toList())
    }

    private fun List<Long>.averageOrZero(): Double = if (isEmpty()) 0.0 else average()

    private fun List<Long>.percentile(p: Double): Double {
        if (isEmpty()) return 0.0
        val rank = ((p / 100.0) * (size - 1)).coerceIn(0.0, (size - 1).toDouble())
        val lower = this[rank.toInt()]
        val upper = this[kotlin.math.ceil(rank).toInt()]
        val fraction = rank - rank.toInt()
        return lower + (upper - lower) * fraction
    }
}

object BenchmarkExporter {
    fun save(bundle: BenchmarkBundle, outputDir: File): BenchmarkSavedFiles {
        outputDir.mkdirs()
        val timestamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date(bundle.summary.finishedAtEpochMs))

        val summaryFile = File(outputDir, "benchmark_summary_${bundle.summary.modelType.name.lowercase()}_$timestamp.json")
        val framesFile = File(outputDir, "benchmark_frames_${bundle.summary.modelType.name.lowercase()}_$timestamp.csv")

        summaryFile.writeText(buildSummaryJson(bundle.summary).toString(2))
        framesFile.writeText(buildFrameCsv(bundle.frames))

        return BenchmarkSavedFiles(summaryFile = summaryFile, frameCsvFile = framesFile)
    }

    private fun buildSummaryJson(summary: BenchmarkSummary): JSONObject {
        return JSONObject()
            .put("model", summary.modelType.displayName)
            .put("duration_ms", summary.durationMs)
            .put("total_frames", summary.totalFrames)
            .put("pose_frames", summary.poseFrames)
            .put("pose_detection_rate", if (summary.totalFrames == 0) 0.0 else summary.poseFrames.toDouble() / summary.totalFrames)
            .put("rep_count", summary.repCount)
            .put("mean_latency_ms", summary.meanLatencyMs)
            .put("p50_latency_ms", summary.p50LatencyMs)
            .put("p95_latency_ms", summary.p95LatencyMs)
            .put("min_latency_ms", summary.minLatencyMs)
            .put("max_latency_ms", summary.maxLatencyMs)
            .put("average_fps", summary.averageFps)
            .put("device_manufacturer", summary.deviceManufacturer)
            .put("device_model", summary.deviceModel)
            .put("android_version", summary.androidVersion)
            .put("started_at_epoch_ms", summary.startedAtEpochMs)
            .put("finished_at_epoch_ms", summary.finishedAtEpochMs)
    }

    private fun buildFrameCsv(frames: List<BenchmarkFrameRecord>): String {
        val header = "relative_timestamp_ms,latency_ms,pose_found,rep_count,stage,representative_angle_deg,avg_confidence,keypoint_count,rolling_fps"
        val body = frames.joinToString(separator = "\n") { frame ->
            listOf(
                frame.relativeTimestampMs,
                frame.latencyMs,
                frame.poseFound,
                frame.repCount,
                frame.stage,
                frame.representativeAngleDeg?.roundToInt() ?: "",
                "%.4f".format(Locale.US, frame.avgConfidence),
                frame.keypointCount,
                "%.2f".format(Locale.US, frame.rollingFps),
            ).joinToString(",")
        }
        return if (body.isBlank()) header else "$header\n$body"
    }
}
