package com.noop.analytics

import kotlin.math.abs
import kotlin.math.roundToInt

/*
 * ActivityCostEngine.kt — "what each activity costs your recovery".
 *
 * Faithful Kotlin mirror of StrandAnalytics/ActivityCostEngine.swift. Keep the tunables,
 * the baseline/next-morning/delta math, the bounce-back trajectory, the confidence gate,
 * and the ranking byte-identical to Swift — cross-platform parity is the contract.
 *
 * Pure, deterministic, DB-free. Given which days you tagged each SPORT on and your daily
 * Charge (recovery, 0–100) history, this answers, per sport: how far does your next-
 * morning Charge sit BELOW your rest-day baseline after a session, and how many days
 * does it take to bounce back?
 *
 * This is a descriptive AVERAGE, not a measurement of any single session — it leans on
 * the levers that are actually in the data (the day a session was tagged, and the Charge
 * values on the days after) and stays explainable line by line. Nothing here is learned;
 * it is plain means over aligned day keys.
 *
 * Per sport S:
 *
 *   restDays      = days with a Charge value that are neither tagged with ANY sport NOR inside
 *                   a session forward recovery window (D+1…D+maxLookahead) — your UNTOUCHED days.
 *   baselineMean  = mean Charge over restDays. The "untouched" recovery bar each sport
 *                   is measured against. (Shared across all sports.)
 *
 *   For each tagged day D of sport S that HAS a Charge value on D+1:
 *     nextMorning(D) = Charge[D+1]
 *   meanNextMorning = mean of those nextMorning(D).
 *   n               = how many tagged days contributed a D+1 value.
 *
 *   delta ("cost")  = baselineMean - meanNextMorning. POSITIVE → the morning after this
 *                     sport your Charge sits BELOW your rest baseline (it cost you);
 *                     negative → you wake higher.
 *
 *   daysToBaseline  = build an AVERAGED forward trajectory traj[k] = mean over tagged
 *                     days D (that have a Charge on D+k) of Charge[D+k], k = 1…maxLookahead.
 *                     daysToBaseline = the smallest k whose traj[k] ≥ baselineMean - tol
 *                     (tol = 3 pts); null if it never gets within tol inside the window or
 *                     n is too thin.
 *
 * Confidence (reuses ScoreConfidence): a sport with fewer than minSessions tagged next-
 * morning pairs is OMITTED entirely; minSessions…<solidSessions → BUILDING; ≥ solidSessions
 * → SOLID.
 *
 * Ranking: biggest |delta| first, SOLID ahead of BUILDING on a tie, then sport name
 * ascending — a fully deterministic, stable order.
 *
 * Day arithmetic mirrors Swift's CorrelationEngine.shiftDay (fixed UTC / proleptic-
 * Gregorian, null on unparseable input) and all means are self-contained.
 */

/**
 * One sport's recovery cost: how far below your rest baseline your next-morning Charge
 * sits after a session of this sport, and how long it takes to bounce back.
 */
data class ActivityCost(
    /** The sport key (raw WHOOP sport / activity name, as tagged on the day). */
    val sport: String,
    /** Signed cost in Charge points: baselineMean - meanNextMorning. Positive = the
     *  morning after sits BELOW your rest baseline (it cost you recovery). */
    val delta: Double,
    /** Mean next-morning (D+1) Charge over tagged days that had a D+1 value, 0–100. */
    val meanNextMorning: Double,
    /** Mean rest-day Charge this sport is measured against (shared across sports), 0–100. */
    val baselineMean: Double,
    /** Days for the averaged forward trajectory to climb back within [ActivityCostEngine.tolerance]
     *  of the baseline; null when it never recovers inside the lookahead window (or too thin). */
    val daysToBaseline: Int?,
    /** Number of tagged days that contributed a D+1 Charge value. */
    val n: Int,
    /** Per-result certainty tier (reuses the Charge/Effort/Rest confidence ladder). */
    val confidence: ScoreConfidence,
) {
    /**
     * Plain-English summary of this sport's recovery cost. Degrades gracefully: drops the
     * bounce-back clause when [daysToBaseline] is null, and says "barely move" when the
     * cost is under a point in either direction.
     */
    fun sentence(): String {
        val mag = abs(delta)
        val points = ActivityCostEngine.roundToIntHalfUp(mag)
        if (mag < ActivityCostEngine.barelyMovesPoints) {
            return "Sessions like this barely move your next-day Charge (n=$n)."
        }
        val direction = if (delta >= 0) "cost you" else "lift"
        val head = "Sessions like this usually $direction about $points Charge " +
            "point${if (points == 1) "" else "s"} the next morning"
        val days = daysToBaseline
        return if (days != null) {
            "$head and take about $days day${if (days == 1) "" else "s"} to bounce back (n=$n)."
        } else {
            "$head (n=$n)."
        }
    }
}

object ActivityCostEngine {

    // Tunables (documented, deterministic — NOT learned). Mirror Swift exactly.

    /** Tagged next-morning pairs below which a sport is OMITTED (too thin to report). */
    const val minSessions: Int = 4

    /** Pairs at/above which a sport's confidence is SOLID (else BUILDING). */
    const val solidSessions: Int = 8

    /** How many days forward the bounce-back trajectory is probed (D+1 … D+maxLookahead). */
    const val maxLookahead: Int = 7

    /** Charge points within the baseline that count as "recovered" for daysToBaseline. */
    const val tolerance: Double = 3.0

    /** |delta| under this (points) reads as "barely moves" in [ActivityCost.sentence]. */
    const val barelyMovesPoints: Double = 1.0

    /**
     * Compute each sport's recovery cost from tagged activity days and daily Charge.
     *
     * @param activityDaysBySport per sport, the SET of "yyyy-MM-dd" day keys that sport was
     *   tagged on. Using a Set means same-day duplicates are already collapsed.
     * @param recoveryByDay daily Charge (recovery, 0–100) keyed by "yyyy-MM-dd".
     * @return one [ActivityCost] per sport that cleared [minSessions], ranked by |delta|
     *   desc, SOLID before BUILDING, sport name ascending on a tie. Empty input (or no
     *   sport thick enough) → an empty list.
     */
    fun evaluate(
        activityDaysBySport: Map<String, Set<String>>,
        recoveryByDay: Map<String, Double>,
    ): List<ActivityCost> {
        if (activityDaysBySport.isEmpty() || recoveryByDay.isEmpty()) return emptyList()

        // Rest days = days WITH a Charge value that are neither tagged with ANY sport NOR inside the
        // forward recovery window (D+1 … D+maxLookahead) of any tagged day. Excluding the after-effect
        // window matters: the mornings AFTER a session are exactly the days the cost suppresses, so
        // counting them as "rest" would contaminate the baseline with the very thing we measure
        // (understating every cost). The baseline must be your genuinely UNTOUCHED days. (Swift parity.)
        val activeUnion = HashSet<String>()
        for ((_, days) in activityDaysBySport) activeUnion.addAll(days)
        val affected = HashSet(activeUnion)
        for (day in activeUnion) {
            for (k in 1..maxLookahead) {
                shiftDay(day, k)?.let { affected.add(it) }
            }
        }
        val restValues = ArrayList<Double>()
        for ((day, value) in recoveryByDay) {
            if (!affected.contains(day)) restValues.add(value)
        }
        // No untouched days → no baseline to measure against → nothing honest to say.
        if (restValues.isEmpty()) return emptyList()
        val baselineMean = mean(restValues)

        val results = ArrayList<ActivityCost>()
        // Sort sports up front so the build order is deterministic regardless of map order.
        for (sport in activityDaysBySport.keys.sorted()) {
            val taggedDays = activityDaysBySport.getValue(sport)

            // Collect next-morning (D+1) Charge for each tagged day that has one.
            val nextMornings = ArrayList<Double>()
            for (day in taggedDays) {
                val d1 = shiftDay(day, 1) ?: continue
                val v = recoveryByDay[d1] ?: continue
                nextMornings.add(v)
            }
            val n = nextMornings.size
            // Thin sports are omitted entirely — better silent than fabricated.
            if (n < minSessions) continue

            val meanNextMorning = mean(nextMornings)
            val delta = baselineMean - meanNextMorning
            val daysToBaseline = forwardDaysToBaseline(taggedDays, recoveryByDay, baselineMean)
            val confidence = if (n >= solidSessions) ScoreConfidence.SOLID else ScoreConfidence.BUILDING

            results.add(
                ActivityCost(
                    sport = sport,
                    delta = delta,
                    meanNextMorning = meanNextMorning,
                    baselineMean = baselineMean,
                    daysToBaseline = daysToBaseline,
                    n = n,
                    confidence = confidence,
                ),
            )
        }

        return rank(results)
    }

    // Bounce-back trajectory.

    /**
     * Smallest k in 1…maxLookahead where the AVERAGED forward Charge trajectory
     * traj[k] = mean over tagged days D (with a Charge on D+k) of Charge[D+k] climbs to
     * within [tolerance] of [baselineMean]. null if it never does inside the window or no
     * day contributed a value at that horizon.
     */
    internal fun forwardDaysToBaseline(
        taggedDays: Set<String>,
        recoveryByDay: Map<String, Double>,
        baselineMean: Double,
    ): Int? {
        val target = baselineMean - tolerance
        for (k in 1..maxLookahead) {
            val vals = ArrayList<Double>()
            for (day in taggedDays) {
                val dk = shiftDay(day, k) ?: continue
                val v = recoveryByDay[dk] ?: continue
                vals.add(v)
            }
            if (vals.isEmpty()) continue
            if (mean(vals) >= target) return k
        }
        return null
    }

    // Ranking.

    /** Stable rank: |delta| desc, then SOLID before BUILDING, then sport name asc. */
    internal fun rank(items: List<ActivityCost>): List<ActivityCost> =
        items.sortedWith(
            compareByDescending<ActivityCost> { abs(it.delta) }
                .thenByDescending { confidenceRank(it.confidence) }
                .thenBy { it.sport },
        )

    /** Ordinal so SOLID sorts ahead of BUILDING (and CALIBRATING last). */
    internal fun confidenceRank(c: ScoreConfidence): Int = when (c) {
        ScoreConfidence.SOLID -> 2
        ScoreConfidence.BUILDING -> 1
        ScoreConfidence.CALIBRATING -> 0
    }

    // Stats (self-contained so the Swift mirror is line-for-line).

    internal fun mean(values: List<Double>): Double {
        if (values.isEmpty()) return 0.0
        return values.sum() / values.size
    }

    /** Round half away from zero to an Int — matches Swift's roundToInt over the
     *  non-negative magnitudes used in [ActivityCost.sentence]. */
    internal fun roundToIntHalfUp(x: Double): Int = x.roundToInt()

    // Day arithmetic — mirrors Swift's CorrelationEngine.shiftDay (fixed UTC calendar;
    // null on unparseable input). Integer-only proleptic-Gregorian, so it is timezone-
    // and locale-free and byte-identical to the Swift result.

    /** Shift a "yyyy-MM-dd" day by [delta] days (may be negative). null if unparseable. */
    internal fun shiftDay(day: String, delta: Int): String? {
        if (delta == 0) return day
        val ymd = parseYMD(day) ?: return null
        val jdn = julianDayNumber(ymd[0], ymd[1], ymd[2]) + delta
        val out = fromJulianDayNumber(jdn)
        return formatYMD(out[0], out[1], out[2])
    }

    private fun parseYMD(s: String): IntArray? {
        val parts = s.split("-")
        if (parts.size != 3) return null
        val y = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        val d = parts[2].toIntOrNull() ?: return null
        if (m !in 1..12 || d < 1 || d > daysInMonth(y, m)) return null
        return intArrayOf(y, m, d)
    }

    private fun daysInMonth(y: Int, m: Int): Int = when (m) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if (isLeap(y)) 29 else 28
        else -> 0
    }

    private fun isLeap(y: Int): Boolean = (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)

    private fun formatYMD(y: Int, m: Int, d: Int): String {
        val yy = if (y < 1000) y.toString().padStart(4, '0') else y.toString()
        val mm = if (m < 10) "0$m" else "$m"
        val dd = if (d < 10) "0$d" else "$d"
        return "$yy-$mm-$dd"
    }

    private fun julianDayNumber(y: Int, m: Int, d: Int): Int {
        val a = (14 - m) / 12
        val yy = y + 4800 - a
        val mm = m + 12 * a - 3
        return d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045
    }

    private fun fromJulianDayNumber(jdn: Int): IntArray {
        val a = jdn + 32044
        val b = (4 * a + 3) / 146097
        val c = a - (146097 * b) / 4
        val dd = (4 * c + 3) / 1461
        val e = c - (1461 * dd) / 4
        val mm = (5 * e + 2) / 153
        val day = e - (153 * mm + 2) / 5 + 1
        val month = mm + 3 - 12 * (mm / 10)
        val year = 100 * b + dd - 4800 + mm / 10
        return intArrayOf(year, month, day)
    }
}
