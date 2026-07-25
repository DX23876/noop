package com.noop.analytics

/**
 * StreakCalculator - consecutive-day "streak" over the days that carry a qualifying record (#569).
 *
 * A streak is the WHOOP-style "days in a row" count. It is derived PURELY from the set of local calendar
 * days that already have a score - no new storage, no migration, no BLE, no network. The caller passes
 * parallel lists ([dayKeys] + [qualified], one entry per day it knows about, the same shape the Charge /
 * HRV surfaces already assemble) plus [today], and gets back the current and longest runs.
 *
 * Civil-day arithmetic is TZ-free ([Baselines.isoEpochDay], Howard Hinnant's algorithm), so Kotlin and
 * Swift agree bit-for-bit. Faithful twin of StrandAnalytics/StreakCalculator.swift, held aligned by
 * mirrored fixtures. Pure and side-effect-free: no clock, no I/O, no PII.
 */
object StreakCalculator {

    /** The current and longest consecutive-day runs. */
    data class Streaks(val current: Int, val longest: Int)

    /**
     * Compute `(current, longest)` from parallel [dayKeys] / [qualified] (`yyyy-MM-dd` keys and their
     * qualify flags) and an ISO [today]. Duplicate or unparseable day keys are ignored; if the lists
     * differ in length the excess is ignored (mirrors [Baselines.nightsSinceNewestValidNight]). Returns
     * `(0, 0)` when nothing qualifies. Pure: no clock, no I/O.
     *
     * [Streaks.current] is the unbroken run of qualifying days ending at [today], or at `today - 1` when
     * today has not been scored yet (a day's score only lands after that night's sleep, so the streak must
     * not read 0 all day). A gap of one or more missed civil days ends the current run. [Streaks.longest]
     * is the longest unbroken run anywhere in the supplied history.
     */
    fun streaks(dayKeys: List<String>, qualified: List<Boolean>, today: String): Streaks {
        // Distinct civil-epoch days that carry a qualifying record.
        val days = HashSet<Int>()
        val n = minOf(dayKeys.size, qualified.size)
        for (i in 0 until n) {
            if (qualified[i]) Baselines.isoEpochDay(dayKeys[i])?.let { days.add(it) }
        }
        if (days.isEmpty()) return Streaks(0, 0)

        // Longest run: start at each day whose predecessor is absent, then count forward.
        var longest = 0
        for (d in days) {
            if (!days.contains(d - 1)) {
                var len = 1
                while (days.contains(d + len)) len++
                if (len > longest) longest = len
            }
        }

        // Current run: anchored at today, or yesterday when today is not yet scored (the grace above).
        var current = 0
        val t = Baselines.isoEpochDay(today)
        if (t != null) {
            val anchor = if (days.contains(t)) t else if (days.contains(t - 1)) t - 1 else null
            if (anchor != null) {
                current = 1
                while (days.contains(anchor - current)) current++
            }
        }
        return Streaks(current, longest)
    }
}
