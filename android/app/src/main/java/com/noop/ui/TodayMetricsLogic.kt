package com.noop.ui

import com.noop.data.AppleDaily
import com.noop.data.WorkoutRow

/** The Today heart-rate card's visible window. */
internal enum class HrWindow(val label: String, val hours: Int) {
    TODAY("Today", 0),
    H24("24h", 24), H12("12h", 12), H6("6h", 6), H3("3h", 3), H1("1h", 1);

    /** Earliest bucket timestamp (unix seconds) this window renders, anchored at `now`. */
    fun cutoff(now: Long): Long = if (this == TODAY) Long.MIN_VALUE else now - hours * 3600L
}

/** Pure narrowing seam: does a loaded bucket survive the HR window cut? */
internal fun hrWindowKeeps(bucketTs: Long, window: HrWindow, now: Long): Boolean =
    bucketTs >= window.cutoff(now)

/** Today footer state cached by the ViewModel across remounts. */
data class TodayFooterState(
    val recentWorkouts: List<WorkoutRow> = emptyList(),
    val whoopDays: Int? = null,
    val whoopWorkouts: Int? = null,
    val appleDays: Int? = null,
    val appleWorkouts: Int? = null,
    val hcDays: Int? = null,
    val hcWorkouts: Int? = null,
)

/** The Today "Last Workouts" contract: cross-source dedup, newest first, at most four. */
internal fun lastWorkoutsFeed(rows: List<WorkoutRow>): List<WorkoutRow> =
    WorkoutEditing.dedupCrossSource(rows)
        .sortedByDescending { it.startTs }
        .take(4)

/** S5: the Key-Metric overflow cap, mirroring TodayView.metricsCollapsedCap. */
internal const val METRICS_COLLAPSED_CAP = 6

/** The Weight tile's display string and an honest caption. */
internal data class WeightTileText(val value: String, val caption: String?)

/** Newest body weight across Apple-side sources, or null when neither carries one. */
internal fun latestWeightKg(apple: List<AppleDaily>, healthConnect: List<AppleDaily>): Double? =
    (apple + healthConnect)
        .filter { it.weightKg != null }
        .maxByOrNull { it.day }
        ?.weightKg

/** Steps for [dayKey] from imported Apple Health / Health Connect daily aggregates. */
internal fun stepsForDay(apple: List<AppleDaily>, healthConnect: List<AppleDaily>, dayKey: String): Int? =
    (apple + healthConnect)
        .filter { it.day == dayKey }
        .mapNotNull { it.steps }
        .maxOrNull()

/** Resolve the Weight tile text from latest imported weight or profile fallback. */
internal fun weightTile(latestWeightKg: Double?, profileWeightKg: Double, system: UnitSystem): WeightTileText =
    if (latestWeightKg != null) {
        WeightTileText(UnitFormatter.massFromKilograms(latestWeightKg, system), "latest")
    } else {
        WeightTileText(UnitFormatter.massFromKilograms(profileWeightKg, system), "from profile")
    }
