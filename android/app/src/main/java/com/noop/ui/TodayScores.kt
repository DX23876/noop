package com.noop.ui

import android.content.Context
import com.noop.core.CoreRead
import java.time.LocalDate

/**
 * Charge, Effort and Rest as Today's rings show them, resolved in ONE place: the day's own scores from the shared
 * core, Charge and Rest carried from the latest scored day while the day has none yet, and Effort live over today's
 * heart rate. Today's hero and both widget producers (the app and the background service) read it, so the home
 * screen can no longer show other figures than the app: the widgets used to rebuild Rest in Kotlin from the old daily
 * row and to fall back to yesterday's Effort (found 2026-11-28, Rest 94 and Effort 44 beside Today's 92 and "–").
 * Blocking; call off the main thread.
 */
object TodayScores {
    data class Scores(val charge: Double?, val effort: Double?, val rest: Double?)

    /** The rings for [shown], given that day's core row [day] (null when the store has none). */
    fun resolve(context: Context, shown: LocalDate, day: CoreRead.Day?, isToday: Boolean): Scores {
        val from = shown.minusDays(14).toString(); val to = shown.toString()
        val charge = day?.charge ?: CoreRead.series(CoreRead.Metric.Charge, from, to).lastOrNull()?.value
        val rest = day?.rest ?: CoreRead.series(CoreRead.Metric.Rest, from, to).lastOrNull()?.value
        val effort = (if (isToday) com.noop.core.CoreLiveEffort.today(context, day?.effort) else null) ?: day?.effort
        return Scores(charge, effort, rest)
    }

    @Volatile private var cached: Pair<String, Scores>? = null

    /**
     * Today's rings for the widget producers, which push at heart-rate cadence: read again only when the logical day,
     * the core's data revision or the minute changes. Null without a core, so a producer keeps its own fallback.
     */
    fun current(context: Context): Scores? {
        if (!com.noop.core.SwiftCore.available) return null
        val today = logicalDayNow()
        val key = "$today|${com.noop.core.CoreShadow.dataRevision.value}|${System.currentTimeMillis() / 60_000}"
        cached?.let { (k, s) -> if (k == key) return s }
        return runCatching {
            CoreRead.open(context)
            resolve(context, today, CoreRead.day(today.toString()), isToday = true)
        }.getOrNull()?.also { cached = key to it }
    }
}
