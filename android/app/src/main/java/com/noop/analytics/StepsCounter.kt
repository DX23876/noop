package com.noop.analytics

import com.noop.data.StepSample

/**
 * Wrap-aware step derivation from the strap's cumulative `step_motion_counter@57`, shared by the daily
 * total ([AnalyticsEngine.analyzeDay]) and any windowed total (a manual workout's `[start, end]`, #398).
 *
 * `step_motion_counter@57` is a CUMULATIVE u16 running counter: it climbs while you move, holds flat when
 * still, and wraps at 65536. The motion-tick total over a set of records is the SUM of WRAP-AWARE
 * increments of that counter — `delta = (cur - prev) and 0xFFFF` — with a per-user `stepTicksPerStep`
 * calibration applied by the caller AFTERWARDS (this returns the raw pre-calibration tick total, so the two
 * callers can never disagree on the counter math). The raw total is an ESTIMATE (@57 counts motion ticks,
 * not validated steps), not cloud/clinical parity.
 *
 * Byte-for-byte twin of the Swift `StepsCounter.stepsInWindow`.
 */
object StepsCounter {
    /**
     * The largest wrap-aware increment treated as real motion between two adjacent 1 Hz records. A delta
     * at/above this is a big time-gap / disconnect boundary between sync sessions (or a firmware reboot,
     * byte-indistinguishable from a u16 wrap), NOT real steps — dropped so gaps don't inflate the total.
     * Real 1 Hz motion never ticks this fast between adjacent records. (#132/#276/#316)
     */
    const val MAX_STEP_DELTA = 512

    /**
     * Raw wrap-aware motion-tick total across [samples] — the sum of positive consecutive
     * `step_motion_counter@57` increments in `[1, MAX_STEP_DELTA)`. Sorts by `ts` internally, so the caller
     * may pass an unsorted window (already filtered to the range it cares about). Returns `null` when there
     * are fewer than two samples or no forward movement (so "no data" stays distinct from a real zero). The
     * caller applies its `stepTicksPerStep` calibration to the returned ticks.
     */
    fun stepsInWindow(samples: List<StepSample>): Int? {
        val sorted = samples.sortedBy { it.ts }
        if (sorted.size < 2) return null
        var total = 0
        for (i in 1 until sorted.size) {
            val delta = (sorted[i].counter - sorted[i - 1].counter) and 0xFFFF // wrap-aware u16 increment
            if (delta in 1 until MAX_STEP_DELTA) total += delta // ignore a delta >= 512 (gap/reset)
        }
        return if (total > 0) total else null
    }
}
