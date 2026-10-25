package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ActivityCostEngineTests.swift.
 * Same fixtures, same numbers — cross-platform parity is the contract.
 */
class ActivityCostEngineTest {

    private fun cost(results: List<ActivityCost>, sport: String): ActivityCost? =
        results.firstOrNull { it.sport == sport }

    private fun ymd(year: Int, month: Int, day: Int): String =
        "%04d-%02d-%02d".format(year, month, day)

    /**
     * Build a consecutive run of tagged days at [value] starting at 2028-[month]-[startDay],
     * so every interior day's D+1 is the next tagged day (n = length−1). Mornings live on
     * tagged days, so they never leak into the rest baseline.
     */
    private fun run(
        rec: MutableMap<String, Double>,
        tagged: MutableSet<String>,
        month: Int,
        startDay: Int,
        length: Int,
        value: Double,
    ) {
        for (i in 0 until length) {
            val day = ymd(2028, month, startDay + i)
            tagged.add(day)
            rec[day] = value
        }
    }

    // Delta sign + value, D+1 keying, baseline excludes active days

    @Test
    fun deltaSignAndValueAndBaselineExcludesActive() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        for (d in 1..9) {
            val day = ymd(2026, 6, d)
            tagged.add(day)
            rec[day] = 50.0   // each active day's own Charge (excluded from baseline)
        }
        for (d in 20..27) rec[ymd(2026, 6, d)] = 70.0

        val out = ActivityCostEngine.evaluate(mapOf("running" to tagged), rec)
        val r = cost(out, "running")
        assertNotNull(r)
        assertEquals(70.0, r!!.baselineMean, 1e-9)       // active 50-days excluded
        assertEquals(50.0, r.meanNextMorning, 1e-9)      // D+1 keyed
        assertEquals(20.0, r.delta, 1e-9)                // +20 cost
        assertEquals(8, r.n)                             // 06-09 has no D+1 value
        assertEquals(ScoreConfidence.SOLID, r.confidence)
    }

    @Test
    fun negativeDeltaWhenNextMorningAboveBaseline() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        for (d in 1..6) {
            val day = ymd(2026, 7, d)
            tagged.add(day)
            rec[day] = 80.0
        }
        for (d in 20..25) rec[ymd(2026, 7, d)] = 60.0

        val out = ActivityCostEngine.evaluate(mapOf("yoga" to tagged), rec)
        val r = cost(out, "yoga")!!
        assertEquals(60.0, r.baselineMean, 1e-9)
        assertEquals(80.0, r.meanNextMorning, 1e-9)   // 5 D+1s (07-06 has no D+1)
        assertEquals(5, r.n)
        assertEquals(-20.0, r.delta, 1e-9)            // you wake ABOVE baseline
    }

    // nil recovery[D+1] is skipped, not counted

    @Test
    fun missingNextMorningIsSkipped() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        for (d in 1..6) {
            val day = ymd(2026, 8, d)
            tagged.add(day)
            if (d != 3) {   // leave 2026-08-04 (the D+1 of day 3) absent
                rec[ymd(2026, 8, d + 1)] = 55.0
            }
        }
        for (d in 20..25) rec[ymd(2026, 8, d)] = 65.0

        val out = ActivityCostEngine.evaluate(mapOf("swim" to tagged), rec)
        val r = cost(out, "swim")!!
        assertEquals(5, r.n)                           // the gap day dropped
        assertEquals(55.0, r.meanNextMorning, 1e-9)
        assertEquals(ScoreConfidence.BUILDING, r.confidence)  // 4 ≤ 5 < 8
    }

    // daysToBaseline: dip-then-recover == 3, and null when never recovers

    // Four session anchors, each the 1st of a different month so the D+1…D+7 forward
    // windows never overlap and there is no month-overflow arithmetic to mirror.
    private val dipAnchors = listOf("2026-01-01", "2026-03-01", "2026-05-01", "2026-07-01")

    /** Shift a "yyyy-MM-dd" day by [n] (mirrors the Swift CorrelationEngine.shiftDay). */
    private fun shift(day: String, n: Int): String = ActivityCostEngine.shiftDay(day, n)!!

    @Test
    fun daysToBaselineDipThenRecover() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        val plus = listOf(1 to 50.0, 2 to 55.0, 3 to 70.0)   // D+1, D+2, D+3
        for (anchor in dipAnchors) {
            tagged.add(anchor)
            for ((k, v) in plus) rec[shift(anchor, k)] = v
        }
        for (i in 1..8) rec[ymd(2026, 11, i)] = 70.0

        val out = ActivityCostEngine.evaluate(mapOf("lift" to tagged), rec)
        val r = cost(out, "lift")!!
        assertEquals(70.0, r.baselineMean, 1e-9)
        assertEquals(3, r.daysToBaseline)
        assertEquals(4, r.n)   // four anchors, each with a D+1 value
    }

    @Test
    fun daysToBaselineNullWhenNeverRecovers() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        for (anchor in dipAnchors) {
            tagged.add(anchor)
            for (k in 1..7) rec[shift(anchor, k)] = 40.0
        }
        for (i in 1..8) rec[ymd(2026, 11, i)] = 70.0

        val out = ActivityCostEngine.evaluate(mapOf("ruck" to tagged), rec)
        val r = cost(out, "ruck")!!
        assertEquals(70.0, r.baselineMean, 1e-9)
        assertNull(r.daysToBaseline)
    }

    // Confidence gate: n=3 omit / n=5 building / n=8 solid

    @Test
    fun confidenceGate() {
        val rec = HashMap<String, Double>()
        val thin = HashSet<String>()   // length 4 → n=3 → OMITTED
        run(rec, thin, month = 1, startDay = 1, length = 4, value = 50.0)
        val mid = HashSet<String>()    // length 6 → n=5 → BUILDING
        run(rec, mid, month = 2, startDay = 1, length = 6, value = 50.0)
        val big = HashSet<String>()    // length 9 → n=8 → SOLID
        run(rec, big, month = 3, startDay = 1, length = 9, value = 50.0)
        for (i in 1..8) rec[ymd(2028, 6, i)] = 70.0

        val out = ActivityCostEngine.evaluate(
            mapOf("thin" to thin, "mid" to mid, "big" to big), rec,
        )

        assertNull(cost(out, "thin"))                              // n=3 omitted
        assertEquals(5, cost(out, "mid")?.n)
        assertEquals(ScoreConfidence.BUILDING, cost(out, "mid")?.confidence)
        assertEquals(8, cost(out, "big")?.n)
        assertEquals(ScoreConfidence.SOLID, cost(out, "big")?.confidence)
        assertEquals(2, out.size)                                  // only mid + big survive
    }

    // Ranking: |delta| desc, solid before building, name asc

    @Test
    fun ranking() {
        val rec = HashMap<String, Double>()
        val alpha = HashSet<String>()
        run(rec, alpha, month = 1, startDay = 1, length = 9, value = 60.0)   // n=8, delta 10
        val bravo = HashSet<String>()
        run(rec, bravo, month = 2, startDay = 1, length = 6, value = 50.0)   // n=5, delta 20
        val charlie = HashSet<String>()
        run(rec, charlie, month = 3, startDay = 1, length = 6, value = 60.0) // n=5, delta 10
        for (i in 1..8) rec[ymd(2028, 6, i)] = 70.0

        val out = ActivityCostEngine.evaluate(
            mapOf("alpha" to alpha, "bravo" to bravo, "charlie" to charlie), rec,
        )
        assertEquals(listOf("bravo", "alpha", "charlie"), out.map { it.sport })
        assertEquals(20.0, cost(out, "bravo")?.delta!!, 1e-9)
        assertEquals(10.0, cost(out, "alpha")?.delta!!, 1e-9)
        assertEquals(10.0, cost(out, "charlie")?.delta!!, 1e-9)
    }

    // Sentence degradation

    @Test
    fun sentenceFull() {
        val c = ActivityCost(
            sport = "running", delta = 12.0, meanNextMorning = 58.0,
            baselineMean = 70.0, daysToBaseline = 2, n = 9, confidence = ScoreConfidence.SOLID,
        )
        assertEquals(
            "Sessions like this usually cost you about 12 Charge points the next morning " +
                "and take about 2 days to bounce back (n=9).",
            c.sentence(),
        )
    }

    @Test
    fun sentenceDropsDaysClauseWhenNull() {
        val c = ActivityCost(
            sport = "running", delta = 12.0, meanNextMorning = 58.0,
            baselineMean = 70.0, daysToBaseline = null, n = 9, confidence = ScoreConfidence.SOLID,
        )
        assertEquals(
            "Sessions like this usually cost you about 12 Charge points the next morning (n=9).",
            c.sentence(),
        )
    }

    @Test
    fun sentenceBarelyMoves() {
        val c = ActivityCost(
            sport = "walk", delta = 0.4, meanNextMorning = 69.6,
            baselineMean = 70.0, daysToBaseline = 1, n = 6, confidence = ScoreConfidence.BUILDING,
        )
        assertEquals("Sessions like this barely move your next-day Charge (n=6).", c.sentence())
    }

    @Test
    fun sentenceLiftDirectionAndSingularDay() {
        val c = ActivityCost(
            sport = "yoga", delta = -1.0, meanNextMorning = 71.0,
            baselineMean = 70.0, daysToBaseline = 1, n = 8, confidence = ScoreConfidence.SOLID,
        )
        assertEquals(
            "Sessions like this usually lift about 1 Charge point the next morning " +
                "and take about 1 day to bounce back (n=8).",
            c.sentence(),
        )
    }

    // Empty input

    @Test
    fun emptyInputs() {
        assertTrue(
            ActivityCostEngine.evaluate(emptyMap(), mapOf("2026-01-01" to 60.0)).isEmpty(),
        )
        assertTrue(
            ActivityCostEngine.evaluate(mapOf("run" to setOf("2026-01-01")), emptyMap()).isEmpty(),
        )
    }

    @Test
    fun noRestDaysYieldsEmpty() {
        val rec = HashMap<String, Double>()
        val tagged = HashSet<String>()
        for (d in 1..8) {
            val day = ymd(2026, 5, d)
            tagged.add(day)
            rec[day] = 50.0
        }
        // Every recovery day is also a tagged day → activeUnion covers them all.
        val out = ActivityCostEngine.evaluate(mapOf("run" to tagged), rec)
        assertTrue(out.isEmpty())
    }

    // Stat helper

    @Test
    fun meanHelper() {
        assertEquals(4.0, ActivityCostEngine.mean(listOf(2.0, 4.0, 6.0)), 1e-9)
        assertEquals(0.0, ActivityCostEngine.mean(emptyList()), 1e-9)
    }
}
