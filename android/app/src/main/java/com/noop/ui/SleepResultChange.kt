package com.noop.ui

import kotlin.math.abs

/** Presentation-only twin of Swift SleepResultChangeTracker. Five minutes is a notification
 * threshold, not an accuracy claim. Stage redistribution alone stays quiet; small changes
 * accumulate against the last announced baseline. */
internal data class SleepResultSnapshot(
    val scope: String,
    val onset: Long,
    val wake: Long,
    val asleepMinutes: Double,
    val edited: Boolean,
)

internal class SleepResultChangeTracker {
    private var baseline: SleepResultSnapshot? = null

    fun observe(next: SleepResultSnapshot?, ready: Boolean): Boolean {
        if (!ready) return false
        if (next == null) { baseline = null; return false }
        val previous = baseline
        if (previous == null || previous.scope != next.scope || previous.edited || next.edited) {
            baseline = next
            return false
        }
        val changed = abs(next.onset - previous.onset) >= 300L ||
            abs(next.wake - previous.wake) >= 300L ||
            abs(next.asleepMinutes - previous.asleepMinutes) >= 5.0
        if (changed) baseline = next
        return changed
    }
}
