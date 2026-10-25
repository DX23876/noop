package com.noop.ble

/**
 * Capped exponential reconnect backoff — the Android twin of the iOS BLEManager schedule
 * (`min(60, 3 * 2^(n-1))`, BLEManager.swift didFailToConnect, #414). A strap that's genuinely out
 * of range must not hammer BLE with a fixed-3s rescan loop; the delay grows 3 → 6 → 12 → 24 → 48 →
 * 60s and then holds at the 60s ceiling. Pure + side-effect-free so it's unit-testable in isolation
 * from the GATT machinery; [WhoopBleClient] owns the attempt counter and resets it on a real connect.
 *
 * Reimplemented under NoopApp from the upstream reconnect-backoff adoption (credit: ryanbr, #48).
 */
internal object ReconnectBackoff {

    /** First (and minimum) delay, matching the iOS base and the previous fixed RECONNECT_DELAY_MS. */
    const val BASE_DELAY_MS = 3_000L

    /** Ceiling — the schedule never waits longer than this between attempts. */
    const val MAX_DELAY_MS = 60_000L

    /**
     * Delay before the [attempt]-th reconnect (1-based: attempt 1 → 3s, 2 → 6s, 3 → 12s, 4 → 24s,
     * 5 → 48s, 6+ → 60s). [attempt] values ≤ 1 (including 0 / negatives, e.g. an uninitialised or
     * underflowed counter) coerce to the base delay rather than producing a sub-base or negative wait.
     *
     * Overflow guard: `3000 shl n` would overflow a Long well before n is large, and even before that
     * it sails past the 60s cap — so for attempt ≥ 6 we short-circuit to [MAX_DELAY_MS]. That keeps the
     * largest shift at `3000 shl 4` (attempt 5 = 48s), the last value below the ceiling.
     */
    fun nextDelayMs(attempt: Int): Long {
        val n = attempt.coerceAtLeast(1)
        if (n >= 6) return MAX_DELAY_MS
        val delay = BASE_DELAY_MS shl (n - 1)   // 3000, 6000, 12000, 24000, 48000
        return delay.coerceAtMost(MAX_DELAY_MS)
    }
}
