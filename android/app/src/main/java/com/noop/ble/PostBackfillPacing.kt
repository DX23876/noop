package com.noop.ble

/**
 * When the scoring pass that follows a backfill may start. It waits for the chunks to stop arriving, as Apple's pass
 * follows a completed backfill: started between two chunks, as it did 1.5 s after the first one, it ran several
 * hundred times a day over the same days and competed with the very chunks it was scoring. A backlog that keeps
 * arriving still gets a pass after [MAX_WAIT_MS], so a long offload shows fresh values on the way.
 */
internal object PostBackfillPacing {
    const val QUIET_MS = 10_000L
    const val MAX_WAIT_MS = 300_000L
    const val POLL_MS = 500L

    /** All three times read from one monotonic clock. */
    fun keepWaiting(nowMs: Long, waitStartedMs: Long, lastChunkMs: Long): Boolean =
        nowMs - lastChunkMs < QUIET_MS && nowMs - waitStartedMs < MAX_WAIT_MS
}
