package com.noop.analytics

import org.json.JSONArray

/**
 * How much of a sleep session's `[startTs, endTs)` span its stage segments actually account for.
 *
 * WHY THIS EXISTS. A session's stage timeline is supposed to TILE its span — `SleepStageTotals` says so
 * explicitly ("the segment stages noop stores ... TILE the window ... Σ stage minutes equals the clock
 * span"), and every consumer is written as though it does. One producer breaks that invariant: a
 * device-PROVIDED hypnogram assembled from records that arrived INCOMPLETE. The Oura path
 * ([com.noop.oura.OuraSleepSessionMapping]) merges only CONTIGUOUS codes, so a sleep-phase page that
 * never arrived leaves a hole in `stagesJSON` while `startTs`/`endTs` still span the whole night. The
 * result is a session that looks well-formed — non-empty, many segments, a plausible efficiency — but
 * describes a fraction of the night it claims.
 *
 * Measured on 31 consecutive ring nights, 8 of them came in under 95% and one covered 23% of its own
 * span (601 min claimed, 140 min of segments). Downstream that night was stored as 70 minutes of sleep
 * against a paired strap's 494, and nothing flagged it: the merge's richness rule tests only that stages
 * are PRESENT, and Rest's two confidence guards are `gravitySparse` (inert here — Oura stores no gravity
 * at all, so `isGravitySparse` returns false for every ring night) and the #H9 restorative floor (needs
 * efficiency >= 0.85; the holed night read 0.50).
 *
 * So the missing quantity is not a new measurement — it is a RATIO of two numbers already stored.
 * Nothing here is persisted and no migration is needed: coverage is derived on read, which also means it
 * applies retroactively to nights already in the database.
 *
 * HONEST-DATA: this only ever reports how much of the night was OBSERVED. It never fills a hole in, and
 * in particular it must not let a caller treat unobserved time as awake — we do not know what happened
 * there, and asserting wake would be the same overreach in the opposite direction.
 *
 * PARITY: pure + deterministic, byte-identical to the Swift twin (`WhoopStore.HypnogramCoverage`). Keep
 * the two in lockstep; `HypnogramCoverageTest` pins the ratio against a Swift-generated oracle.
 */
object HypnogramCoverage {

    /**
     * Coverage at or above which a stage timeline is treated as describing its whole span.
     *
     * The observed split is wide: healthy nights land at 99–100%, the broken ones at 23–93%. 0.95 sits
     * in the empty middle, so the gate is not balanced on the edge of the data. Mirrors Swift
     * `minCoverage`.
     */
    const val minCoverage: Double = 0.95

    /**
     * The covered fraction of [spanSeconds], or null when the question does not apply.
     *
     * Returns null — meaning "unknown, do not judge" — rather than 0 when there is nothing to measure,
     * so an unknown coverage can never be mistaken for a bad one by a caller comparing against
     * [minCoverage]. Clamped to at most 1: segments that overlap or overhang would otherwise report more
     * than a full night, and for a completeness gate the safe direction is to read that as "complete"
     * rather than to invent a failure out of malformed input.
     */
    fun fraction(coveredSeconds: Double, spanSeconds: Double): Double? {
        if (spanSeconds <= 0.0 || coveredSeconds <= 0.0) return null
        return minOf(1.0, coveredSeconds / spanSeconds)
    }

    /**
     * The covered fraction of [spanSeconds] for a session's stored `stagesJSON`, or null when coverage is
     * not a meaningful question for that payload.
     *
     * null for: a null/blank/`"[]"` payload (no stages at all — that is the richness question, not this
     * one) and for the IMPORTED minute-dict shape `{light,deep,rem,awake}`, which carries no timestamps
     * and therefore cannot be compared against a span. That second case is what keeps this gate away from
     * WHOOP/Apple/Health-Connect imports entirely: they are never judged incomplete here, so no existing
     * import behaviour changes.
     */
    fun fraction(stagesJson: String?, spanSeconds: Double): Double? {
        val json = stagesJson?.trim() ?: return null
        if (json.isEmpty() || json == "[]") return null
        // The dict shape (imported minute totals) throws here and falls through to null — deliberately,
        // since it carries no timestamps to measure. Same try/catch idiom as SleepStageTotals.minutes.
        val arr = try { JSONArray(json) } catch (_: Throwable) { return null }
        var covered = 0.0
        for (i in 0 until arr.length()) {
            val seg = arr.optJSONObject(i) ?: continue
            if (!seg.has("start") || !seg.has("end")) continue
            val s = seg.optDouble("start", Double.NaN)
            val e = seg.optDouble("end", Double.NaN)
            if (s.isNaN() || e.isNaN() || e <= s) continue
            covered += e - s
        }
        return fraction(covered, spanSeconds)
    }

    /**
     * True when the timeline is known to cover less than [minCoverage] of its span — i.e. the session
     * demonstrably describes only part of the night it claims. Unknown coverage (null) is NOT holed:
     * every guard built on this fails OPEN, so a payload shape this cannot measure keeps its existing
     * behaviour instead of being silently downgraded.
     */
    fun isHoled(stagesJson: String?, spanSeconds: Double): Boolean {
        val f = fraction(stagesJson, spanSeconds) ?: return false
        return f < minCoverage
    }
}
