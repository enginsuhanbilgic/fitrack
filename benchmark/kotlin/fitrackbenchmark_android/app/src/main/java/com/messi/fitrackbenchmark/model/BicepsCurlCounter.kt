package com.messi.fitrackbenchmark.model

import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

data class CurlSnapshot(
    val representativeAngleDeg: Float?,
    val reps: Int,
    val stage: String,
)

class BicepsCurlCounter(
    private val minConfidence: Float = 0.45f,
    private val curlUpThresholdDeg: Float = 65f,
    private val curlDownThresholdDeg: Float = 145f,
) {
    private var stage: String = "UNKNOWN"
    private var reps: Int = 0
    private val recentAngles = ArrayDeque<Float>()

    fun reset() {
        stage = "UNKNOWN"
        reps = 0
        recentAngles.clear()
    }

    fun update(result: PoseFrameResult): CurlSnapshot {
        val candidateAngles = mutableListOf<Float>()

        computeArmAngle(
            result.point(PoseSchema.LEFT_SHOULDER),
            result.point(PoseSchema.LEFT_ELBOW),
            result.point(PoseSchema.LEFT_WRIST),
        )?.let(candidateAngles::add)

        computeArmAngle(
            result.point(PoseSchema.RIGHT_SHOULDER),
            result.point(PoseSchema.RIGHT_ELBOW),
            result.point(PoseSchema.RIGHT_WRIST),
        )?.let(candidateAngles::add)

        val representativeAngle = if (candidateAngles.isEmpty()) {
            null
        } else {
            candidateAngles.average().toFloat()
        }

        representativeAngle?.let {
            recentAngles.addLast(it)
            while (recentAngles.size > 5) {
                recentAngles.removeFirst()
            }

            val smoothed = recentAngles.average().toFloat()

            if (stage == "UNKNOWN") {
                stage = if (smoothed >= curlDownThresholdDeg) "DOWN" else "UP"
            }

            if (smoothed <= curlUpThresholdDeg) {
                stage = "UP"
            } else if (stage == "UP" && smoothed >= curlDownThresholdDeg) {
                stage = "DOWN"
                reps += 1
            }

            return CurlSnapshot(smoothed, reps, stage)
        }

        return CurlSnapshot(null, reps, stage)
    }

    private fun computeArmAngle(
        shoulder: PosePoint?,
        elbow: PosePoint?,
        wrist: PosePoint?,
    ): Float? {
        if (shoulder == null || elbow == null || wrist == null) return null
        if (shoulder.score < minConfidence || elbow.score < minConfidence || wrist.score < minConfidence) {
            return null
        }

        val abx = shoulder.xNormalized - elbow.xNormalized
        val aby = shoulder.yNormalized - elbow.yNormalized
        val cbx = wrist.xNormalized - elbow.xNormalized
        val cby = wrist.yNormalized - elbow.yNormalized

        val dot = abx * cbx + aby * cby
        val mag1 = sqrt(abx.pow(2) + aby.pow(2))
        val mag2 = sqrt(cbx.pow(2) + cby.pow(2))
        if (mag1 == 0f || mag2 == 0f) return null

        val cosTheta = min(1f, max(-1f, dot / (mag1 * mag2)))
        return Math.toDegrees(acos(cosTheta).toDouble()).toFloat()
    }
}
