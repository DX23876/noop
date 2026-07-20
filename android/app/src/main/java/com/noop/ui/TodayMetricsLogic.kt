package com.noop.ui

import com.noop.data.AppleDaily
import com.noop.data.WorkoutRow

/**
 * The Today heart-rate card's visible window. TODAY means "the whole selected calendar day" (every
 * loaded day since the logical midnight) - the unchanged default. The rest are rolling "last N hours"
 * ending now. VIEW-ONLY, the #829 zoom rule: a window only narrows which of the already-loaded 5-minute
 * buckets render - it never re-queries the DB and never changes the bucket resolution. (PR #985 proposed
 * re-reading shorter windows at finer buckets; that adds a DB round-trip per tap and a second read path
 * for detail that already has a home, the Deep Timeline re-reads down to raw seconds as you zoom.)
 * Because the loaded extent starts at midnight, a window clips to the day: early in the morning the wider
 * windows coincide with Today, which reads fine - both mean "everything so far". Only offered on the
 * CURRENT day: a past day has no "now", so it always shows the full calendar day, exactly as before.
 */
internal enum class HrWindow(val label: String, val hours: Int) {
    // Declaration order IS the pill order: Today (the whole loaded day) anchors the wide end, then
    // strictly most -> least hours. TODAY stays ordinal 0 so the rememberSaveable default is the full day.
    TODAY("Today", 0),
    H24("24h", 24), H12("12h", 12), H6("6h", 6), H3("3h", 3), H1("1h", 1);

    /** Earliest bucket timestamp (unix seconds) this window renders, anchored at `now`. TODAY = no
     *  narrowing. Anchoring at the wall clock (not the newest banked bucket) keeps the card honest: a
     *  strap that hasn't offloaded for two hours shows "no heart rate in the last 1h", never a silently
     *  re-anchored older hour - and the empty state keeps the pills, so it's not a dead end. */
    fun cutoff(now: Long): Long = if (this == TODAY) Long.MIN_VALUE else now - hours * 3600L
}

/** The pure narrowing seam (locked by HrWindowTest): does a loaded bucket survive the window's cut?
 *  The filter only ever drops OLD buckets, so the newest bucket always survives a non-empty cut and the
 *  card's trailing "latest bpm" read-out is window-invariant. */
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

/** S5: the Key-Metric overflow cap, mirroring TodayView.metricsCollapsedCap (two columns, three rows). */
internal const val METRICS_COLLAPSED_CAP = 6

/** The Weight tile's display string and an honest caption. */
internal data class WeightTileText(val value: String, val caption: String?)

/**
 * The newest body weight across the two Apple-side sources (apple-health + health-connect), or null
 * when neither carries one. Days are ISO `yyyy-MM-dd`, which sorts chronologically, so the lexically
 * greatest day with a non-null `weightKg` is the most recent, no date parsing needed. (#107)
 */
internal fun latestWeightKg(apple: List<AppleDaily>, healthConnect: List<AppleDaily>): Double? =
    (apple + healthConnect)
        .filter { it.weightKg != null }
        .maxByOrNull { it.day }
        ?.weightKg

/**
 * Steps for [dayKey] from the imported Apple Health / Health Connect daily aggregates, or null when
 * neither source carries a step total for that day. Backs the Today Steps-tile fallback for straps
 * NOOP can't read steps off over Bluetooth, notably the WHOOP 4.0, which DOES count steps (in the
 * official WHOOP app) but doesn't expose them to NOOP, so on a 4.0 the tile shows imported steps
 * rather than "No Data". On-device WHOOP 5/MG steps (DailyMetric.steps) still take precedence at the
 * call site. When both sources report the same day, the larger (most-complete) total wins so we never
 * sum and double-count. Mirrors the macOS TodayView, which already falls back to imported steps. (#150)
 */
internal fun stepsForDay(apple: List<AppleDaily>, healthConnect: List<AppleDaily>, dayKey: String): Int? =
    (apple + healthConnect)
        .filter { it.day == dayKey }
        .mapNotNull { it.steps }
        .maxOrNull()

/**
 * Resolve the Weight tile text: prefer the latest Apple/Health-Connect weight, else fall back to the
 * SI profile weight with a "from profile" caption so the source stays honest. Both are formatted
 * through the shared [UnitFormatter] so the Imperial/Metric toggle reaches this tile too. (#107)
 */
internal fun weightTile(latestWeightKg: Double?, profileWeightKg: Double, system: UnitSystem): WeightTileText =
    if (latestWeightKg != null) {
        WeightTileText(UnitFormatter.massFromKilograms(latestWeightKg, system), "latest")
    } else {
        WeightTileText(UnitFormatter.massFromKilograms(profileWeightKg, system), "from profile")
    }
