package com.messi.fitrackbenchmark.util

class RollingFpsCounter(
    private val windowMs: Long = 1_000L,
) {
    private val frameCompletionTimes = ArrayDeque<Long>()

    fun reset() {
        frameCompletionTimes.clear()
    }

    fun onFrameCompleted(timestampMs: Long): Double {
        frameCompletionTimes.addLast(timestampMs)
        while (frameCompletionTimes.isNotEmpty() && timestampMs - frameCompletionTimes.first() > windowMs) {
            frameCompletionTimes.removeFirst()
        }
        return if (frameCompletionTimes.size < 2) 0.0
        else frameCompletionTimes.size * 1000.0 / windowMs.toDouble()
    }
}
