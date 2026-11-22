package com.noop.ble

/**
 * When the scoring pass that follows a backfill may start. It waits for the chunks to stop arriving, as Apple's pass
 * follows a completed backfill: started between two chunks, as it did 1.5 s after the first one, it ran several
 * hundred times a day over the same days and competed with the very chunks it was scoring. A backlog that keeps
 * arriving still gets a pass after [MAX_WAIT_MS], so a long offload shows fresh values on the way.
 */
internal object PostBackfillPacing {
    const val QUIET_MS = 10_000L

    /**
     * Fork (DX23876), 2026-11-22: the Swift twin (`Strand/BLE/PostBackfillPacing.swift`) caps at half an
     * hour instead, and says why — an auto-continued chain on the owner's phone ran about ten minutes, so
     * five would release the pass with the night half offloaded. The number is deliberately not shared:
     * there, the cheap current-day refresh runs per slice and is what keeps the screen moving, while a
     * pass released by this cap is Apple's whole pass. Here the follow-up re-arm
     * (`analyzeAfterBackfillPending`) scores the night again when the next chunk lands, so a pass
     * released early is corrected rather than left standing. If that ever stops being true, this cap has
     * the Apple bug.
     */
    const val MAX_WAIT_MS = 300_000L
    const val POLL_MS = 500L

    /** All three times read from one monotonic clock. */
    fun keepWaiting(nowMs: Long, waitStartedMs: Long, lastChunkMs: Long): Boolean =
        nowMs - lastChunkMs < QUIET_MS && nowMs - waitStartedMs < MAX_WAIT_MS
}
