package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [displaySmoothed], the Kotlin port of Swift `Hypnogram.displaySmoothed`
 * (Packages/StrandDesign/Sources/StrandDesign/Hypnogram.swift). Fixtures mirror the Swift
 * semantics: coalesce adjacent same-stage runs, then absorb the SHORTEST sub-threshold fragment
 * into its LONGER neighbour until every block clears the floor. Render-only smoothing.
 */
class StageDisplaySmoothingTest {

    private fun iv(stage: String, start: Double, end: Double) = StageInterval(stage, start, end)

    @Test
    fun guardsTwoOrFewerIntervalsUntouched() {
        val two = listOf(iv("light", 0.0, 30.0), iv("deep", 30.0, 60.0))
        assertEquals(two, displaySmoothed(two, 90.0))   // Swift: guard sorted.count > 2
    }

    @Test
    fun coalescesAdjacentSameStageRuns() {
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 300.0),
                iv("light", 300.0, 600.0),   // same stage, zero-length seam → merged
                iv("deep", 600.0, 900.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 600.0), out[0])
        assertEquals(iv("deep", 600.0, 900.0), out[1])
    }

    @Test
    fun absorbsFlickerIntoLongerNeighbour() {
        // A 30 s deep flicker between 600 s light (longer) and 300 s rem → absorbed into light.
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 600.0),
                iv("deep", 600.0, 630.0),
                iv("rem", 630.0, 930.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 630.0), out[0])
        assertEquals(iv("rem", 630.0, 930.0), out[1])
    }

    @Test
    fun absorptionReCoalescesBridgedRuns() {
        // light | 30s wake | light → wake absorbed, then the two light runs coalesce into ONE block.
        val out = displaySmoothed(
            listOf(
                iv("light", 0.0, 600.0),
                iv("wake", 600.0, 630.0),
                iv("light", 630.0, 1200.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(1, out.size)
        assertEquals(iv("light", 0.0, 1200.0), out[0])
    }

    @Test
    fun edgeFragmentAbsorbsIntoOnlyNeighbour() {
        val out = displaySmoothed(
            listOf(
                iv("wake", 0.0, 30.0),      // leading flicker: only neighbour is `light`
                iv("light", 30.0, 900.0),
                iv("deep", 900.0, 1800.0),
            ),
            minDurationSec = 90.0,
        )
        assertEquals(2, out.size)
        assertEquals(iv("light", 0.0, 900.0), out[0])
    }

    @Test
    fun combOfEpochFlickersCollapses() {
        // 30 s-epoch comb (the original complaint): alternating light/deep flickers inside a light
        // night collapse to a single light block — no sub-90 s block survives.
        val comb = buildList {
            add(iv("light", 0.0, 1200.0))
            var t = 1200.0
            repeat(6) {
                add(iv("deep", t, t + 30.0)); t += 30.0
                add(iv("light", t, t + 30.0)); t += 30.0
            }
            add(iv("light", t, t + 1200.0))
        }
        val out = displaySmoothed(comb, 90.0)
        assertTrue(out.all { it.durationSec >= 90.0 })
        assertEquals(1, out.size)
        assertEquals("light", out[0].stage)
        assertEquals(0.0, out[0].startSec, 1e-9)
        assertEquals(comb.last().endSec, out[0].endSec, 1e-9)
    }

    @Test
    fun zeroFloorReturnsCoalescedInputUnsmoothed() {
        // minDurationSec = 0 ("raw") must still COALESCE adjacent same-stage runs (Swift parity) — NOT
        // return the un-merged epoch fragments. Fixture has an adjacent light/light seam so it actually
        // exercises the coalesce (the previous [light, deep, rem] fixture had none, so it passed even
        // when the impl short-circuited to raw).
        val raw = listOf(iv("light", 0.0, 10.0), iv("light", 10.0, 20.0), iv("deep", 20.0, 30.0))
        val coalesced = listOf(iv("light", 0.0, 20.0), iv("deep", 20.0, 30.0))
        assertEquals(coalesced, displaySmoothed(raw, 0.0))
    }

    @Test
    fun totalsPreserved() {
        val raw = listOf(
            iv("light", 0.0, 600.0), iv("deep", 600.0, 660.0),
            iv("rem", 660.0, 1500.0), iv("wake", 1500.0, 1530.0), iv("light", 1530.0, 3000.0),
        )
        val out = displaySmoothed(raw, 90.0)
        assertEquals(0.0, out.first().startSec, 1e-9)
        assertEquals(3000.0, out.last().endSec, 1e-9)
        for (i in 1 until out.size) assertEquals(out[i - 1].endSec, out[i].startSec, 1e-9)
    }
}
