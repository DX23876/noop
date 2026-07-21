package com.noop.ui

import com.noop.analytics.RestScorer
import com.noop.data.DailyMetric

/** A short Rest state word for the hero gauge — same banding the synthesis hero uses. */
internal fun sleepScoreWord(score: Double): String = when {
    score < 50.0 -> "Poor"
    score < 70.0 -> "Fair"
    score < 85.0 -> "Good"
    else -> "Optimal"
}

/**
 * Short night-relative label ("Last night" / "1 night ago" / "N nights ago") for the ◀/▶-navigated
 * night. Shared by the Rest hero overline and the hypnogram nav header so both name the SAME night
 * the hero's score is resolved for. Mirrors iOS SleepView.nightRelativeLabel.
 */
internal fun nightRelativeLabel(offset: Int): String = when (offset) {
    0 -> "Last night"
    1 -> "1 night ago"
    else -> "$offset nights ago"
}

/**
 * The sleep-performance score (0–100) for a SPECIFIC navigated night: the imported WHOOP figure for
 * that night's wake-day when the export carried one, else the resolved Rest composite for that day.
 * Mirrors the per-day transform in [buildSleepModel]'s `performance` series (and iOS
 * SleepView.performanceScore), keyed by [HeroNight.dayKey], so a navigated past night reads ITS OWN
 * score rather than the full-history latest. Null when there is no navigated night or that day has
 * no score.
 */
internal fun heroPerformanceScore(
    night: HeroNight?, days: List<DailyMetric>, imported: ImportedSleepSeries,
): Double? {
    val wakeDay = night?.dayKey ?: return null
    imported.performance[wakeDay]?.let { return it }
    val daily = days.lastOrNull { it.day == wakeDay } ?: return null
    return RestScorer.restFromDaily(daily)
}

/**
 * Whether a SPECIFIC night's sleep-performance score is WHOOP's own imported figure or NOOP's
 * on-device approximation — so the hero is honest about provenance, like Today's badges. Keyed by the
 * night's wake-day (matching [heroPerformanceScore]) so a navigated night's badge tracks ITS OWN
 * score's provenance, not last night's. Mirrors the macOS SleepView.heroSource.
 */
internal fun restHeroSource(imported: ImportedSleepSeries, wakeDay: String?): String =
    if (wakeDay != null && imported.performance[wakeDay] != null) "Whoop" else "On-device"
