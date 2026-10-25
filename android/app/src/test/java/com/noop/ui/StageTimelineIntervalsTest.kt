package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [stageIntervalsFromWeights], the pure helper behind the Sleep hero's per-stage
 * timeline rows (iOS #988 port). Reconstructs (stage, startSec, endSec) intervals from the hero's
 * ordered `realSegments` weight pairs by walking cumulative fractions across the night span.
 */
class StageTimelineIntervalsTest {

    @Test
    fun walksCumulativeFractions() {
        // 30 + 60 + 30 = 120 min of weights across a 7200 s span → fractions 1/4, 1/2, 1/4.
        val ivs = stageIntervalsFromWeights(
            listOf("light" to 30f, "deep" to 60f, "rem" to 30f),
            spanSec = 7200.0,
        )
        assertEquals(3, ivs.size)
        assertEquals(0.0, ivs[0].startSec, 1e-9)
        assertEquals(1800.0, ivs[0].endSec, 1e-9)
        assertEquals("deep", ivs[1].stage)
        assertEquals(1800.0, ivs[1].startSec, 1e-9)
        assertEquals(5400.0, ivs[1].endSec, 1e-9)
        assertEquals(7200.0, ivs[2].endSec, 1e-9)
    }

    @Test
    fun intervalsAreContiguousAndCoverSpan() {
        val ivs = stageIntervalsFromWeights(
            listOf("wake" to 5f, "light" to 90f, "deep" to 45f, "light" to 100f, "rem" to 40f),
            spanSec = 28_800.0,
        )
        assertEquals(0.0, ivs.first().startSec, 1e-9)
        assertEquals(28_800.0, ivs.last().endSec, 1e-6)
        for (i in 1 until ivs.size) assertEquals(ivs[i - 1].endSec, ivs[i].startSec, 1e-9)
    }

    @Test
    fun skipsNonFiniteAndNonPositiveWeights() {
        val ivs = stageIntervalsFromWeights(
            listOf("light" to 30f, "deep" to Float.NaN, "rem" to -5f, "light" to 0f, "deep" to 30f),
            spanSec = 3600.0,
        )
        assertEquals(2, ivs.size)
        assertEquals("light", ivs[0].stage)
        assertEquals("deep", ivs[1].stage)
        // The two surviving 30 min weights split the span in half.
        assertEquals(1800.0, ivs[0].endSec, 1e-9)
        assertEquals(3600.0, ivs[1].endSec, 1e-9)
    }

    @Test
    fun emptyOrDegenerateInputReturnsEmpty() {
        assertTrue(stageIntervalsFromWeights(emptyList(), 3600.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), 0.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), -10.0).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 30f), Double.NaN).isEmpty())
        assertTrue(stageIntervalsFromWeights(listOf("light" to 0f, "deep" to Float.NaN), 3600.0).isEmpty())
    }

    @Test
    fun durationSecIsEndMinusStart() {
        val ivs = stageIntervalsFromWeights(listOf("light" to 30f, "deep" to 30f), 3600.0)
        assertEquals(1800.0, ivs[0].durationSec, 1e-9)
    }
}
