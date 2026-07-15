package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the baseline-merge precedence in `IntelligenceEngine.mergeNightlyIntoHistory` (the
 * "Needs the strap" / recovery-No-Data starvation). An imported history row that carries a
 * NULL value for a metric holds no information for that day: it must NOT shadow the real
 * on-device nightly value into a permanently missing night, or an import whose rows are
 * blank for avgHrv/restingHr blankets every strap-covered day and the baseline never
 * crosses Baselines.minNightsSeed. Precedence pinned here:
 *
 *   1. imported non-null  → wins over the computed value (import users unchanged)
 *   2. key absent         → computed value fills (the BLE-only recovery fix)
 *   3. imported NULL      → computed value backfills (the shadow fix)
 *   4. imported NULL, no computed value → stays a missing night (honest gap)
 *
 * Mirrors the Swift `IntelligenceBaselineShadowTests` so the two platforms merge identically.
 */
class IntelligenceBaselineShadowTest {

    @Test
    fun importedNonNull_winsOverComputed() {
        val hist = linkedMapOf<String, Double?>("2026-07-10" to 62.0)
        IntelligenceEngine.mergeNightlyIntoHistory(hist, mapOf("2026-07-10" to 48.0))
        assertEquals(62.0, hist["2026-07-10"]!!, 1e-9)
    }

    @Test
    fun dayNotImported_computedFills() {
        val hist = linkedMapOf<String, Double?>("2026-07-10" to 62.0)
        IntelligenceEngine.mergeNightlyIntoHistory(hist, mapOf("2026-07-11" to 48.0))
        assertEquals(48.0, hist["2026-07-11"]!!, 1e-9)
        assertEquals(2, hist.size)
    }

    @Test
    fun importedNullValue_backfilledByComputed() {
        // THE bug: the user's Health Connect import wrote a row for the day with a blank
        // avgHrv; the strap actually scored the night. The blank row must not shadow it.
        val hist = linkedMapOf<String, Double?>("2026-07-10" to null)
        IntelligenceEngine.mergeNightlyIntoHistory(hist, mapOf("2026-07-10" to 48.0))
        assertEquals(
            "an imported row with a null value must be backfilled by the real computed night",
            48.0, hist["2026-07-10"]!!, 1e-9,
        )
    }

    @Test
    fun importedNullValue_noComputed_staysMissing() {
        val hist = linkedMapOf<String, Double?>("2026-07-10" to null)
        IntelligenceEngine.mergeNightlyIntoHistory(hist, emptyMap())
        assertTrue("2026-07-10" in hist)
        assertNull(hist["2026-07-10"])
    }

    @Test
    fun nullComputed_doesNotDisturbAnything() {
        // A computed pass that produced no value for a day it emitted (nil estimate) neither
        // overwrites an imported value nor un-registers an imported-null day.
        val hist = linkedMapOf<String, Double?>("2026-07-10" to 62.0, "2026-07-11" to null)
        IntelligenceEngine.mergeNightlyIntoHistory(
            hist, mapOf("2026-07-10" to null, "2026-07-11" to null, "2026-07-12" to null),
        )
        assertEquals(62.0, hist["2026-07-10"]!!, 1e-9)
        assertNull(hist["2026-07-11"])
        assertTrue("2026-07-12" in hist)
        assertNull(hist["2026-07-12"])
    }

    @Test
    fun starvationShape_endToEnd() {
        // The report's shape: a week of imported rows, ALL blank for HRV, over nights the
        // strap scored. After the merge the fold input must contain the 7 real values, so
        // the baseline can cross Baselines.minNightsSeed instead of reading "No Data".
        val hist = LinkedHashMap<String, Double?>()
        val nightly = LinkedHashMap<String, Double?>()
        for (i in 6 downTo 0) {
            val day = "2026-07-%02d".format(12 - i)
            hist[day] = null
            nightly[day] = 50.0 + i
        }
        IntelligenceEngine.mergeNightlyIntoHistory(hist, nightly)
        val valid = hist.values.filterNotNull()
        assertEquals("all 7 strap nights must survive the merge", 7, valid.size)
        assertTrue(valid.size >= Baselines.minNightsSeed)
    }
}
