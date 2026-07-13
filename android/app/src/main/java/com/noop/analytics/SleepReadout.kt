package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample

// SleepReadout.kt - Kotlin twin of SleepReadout.swift. Pure values for the Sleep live-readout
// panel. No state, no IO, no em-dashes.

object SleepReadout {
    /** HR samples per minute over the stream's own span. 0 when fewer than 2 samples. */
    fun hrDensityPerMinute(hr: List<HrSample>): Double {
        if (hr.size < 2) return 0.0
        val sorted = hr.sortedBy { it.ts }
        val spanS = (sorted.last().ts - sorted.first().ts).toDouble()
        if (spanS <= 0) return 0.0
        return sorted.size / (spanS / 60.0)
    }

    /** Fraction of the HR window the gravity stream spans, in [0, 1]. Below SleepStager's
     *  sparseGravitySpanFrac means tonight's gravity is sparse. */
    fun gravityCoverageFraction(gravity: List<GravitySample>, hr: List<HrSample>): Double {
        if (gravity.size < 2 || hr.size < 2) return 0.0
        val g = gravity.sortedBy { it.ts }
        val h = hr.sortedBy { it.ts }
        val hrSpan = (h.last().ts - h.first().ts).toDouble()
        if (hrSpan <= 0) return 0.0
        val gravSpan = (g.last().ts - g.first().ts).toDouble()
        return maxOf(0.0, minOf(1.0, gravSpan / hrSpan))
    }

    /** The gate named by the most recent gate-trace line in the tagged log tail, or null. */
    fun lastGateFired(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val idx = line.indexOf("gate=")
            if (idx < 0) continue
            val after = line.substring(idx + "gate=".length)
            val token = after.takeWhile { it != ' ' }
            if (token.isNotEmpty()) return token
        }
        return null
    }
}

/**
 * Pure values for the Recovery (Charge) and HRV live-readout panels (Test Centre Group G). Kotlin twin of
 * the Swift TestReadout. Each parses the tagged log tail the Recovery / HRV emitters write, so the panel
 * reflects exactly the last Charge breakdown or HRV computation. No state, no IO, no em-dashes.
 */
object TestReadout {

    /**
     * The Charge outcome for the MOST RECENT day from the RECOVERY-tagged tail, or null. The emitter writes
     * "[recovery] charge day=<yyyy-MM-dd> ... score=<n> band=<b> ..." (or a "nilScore reason=..." line when
     * that day could not be scored). Returns the score/band fragment so the panel reads the same number the
     * dashboard shows; falls back to the nil-reason only when the NEWEST day genuinely has none.
     *
     * #343: the engine emits days NEWEST-FIRST (and may replay several passes), so the LAST line in the tail
     * is the OLDEST window-edge day — routinely a cold-start `nilScore missingInput` (no baseline history at
     * the window's far edge). Scanning in reverse therefore surfaced that stale edge day and read "no score
     * (input missing)" even when today's Charge was a healthy green. Instead select by the newest `day=`
     * (ISO dates compare lexicographically), order-independently, preferring the last pass. Mirrors Swift.
     */
    fun lastChargeBreakdown(taggedTail: List<String>): String? {
        var bestDay = ""
        var outcome: String? = null
        for (line in taggedTail) {
            val di = line.indexOf("day=")
            if (di < 0) continue
            val day = line.substring(di + 4).take(10)
            if (day.length != 10 || day < bestDay) continue
            val parsed: String? = run {
                val si = line.indexOf("score=")
                if (si >= 0) {
                    val upto = line.substring(si).takeWhile { it != '(' }.trim()
                    if (upto.isNotEmpty()) return@run upto
                }
                val ni = line.indexOf("nilScore reason=")
                if (ni >= 0) {
                    val token = line.substring(ni + "nilScore reason=".length).takeWhile { it != ' ' }
                    if (token.isNotEmpty()) return@run "no score ($token)"
                }
                null   // a baseline/term line for this day carries no outcome — skip it
            } ?: continue
            if (day > bestDay) bestDay = day   // a strictly newer day with an outcome resets the winner
            outcome = parsed                    // newest day (or a later pass of it) → its outcome wins
        }
        return outcome
    }

    /**
     * The most recent HRV result fragment from the HRV-tagged tail, or null. The emitter writes
     * "[hrv] hrv rmssd=<n>ms sdnn=<n>ms meanNN=<n>ms" on success, or "[hrv] hrv result=nil (..)" when a
     * gate refused the reading. Returns the rmssd/sdnn fragment, or the nil note, so the panel reads the
     * same outcome the snapshot screen showed. Mirrors the Swift parser.
     */
    fun lastHrvComputation(taggedTail: List<String>): String? {
        for (line in taggedTail.asReversed()) {
            val ri = line.indexOf("rmssd=")
            if (ri >= 0) {
                val frag = line.substring(ri).trim()
                if (frag.isNotEmpty()) return frag
            }
            if (line.contains("result=nil")) return "no reading (filtered out)"
        }
        return null
    }
}
