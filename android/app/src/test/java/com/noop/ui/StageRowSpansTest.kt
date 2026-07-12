package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [canonicalStage] + [stageRowSpans]: the (fracStart, fracWidth) spans of one
 * stage's intervals within the night, feeding a single StageRowTrack canvas per timeline row.
 */
class StageRowSpansTest {

    private val ivs = listOf(
        StageInterval("wake", 0.0, 360.0),
        StageInterval("light", 360.0, 1800.0),
        StageInterval("deep", 1800.0, 2520.0),
        StageInterval("light", 2520.0, 3240.0),
        StageInterval("Awake", 3240.0, 3600.0),
    )

    @Test
    fun extractsFractionalSpansForOneStage() {
        val spans = stageRowSpans(ivs, "Light", 3600.0)
        assertEquals(2, spans.size)
        assertEquals(0.1f, spans[0].first, 1e-6f)
        assertEquals(0.4f, spans[0].second, 1e-6f)
        assertEquals(0.7f, spans[1].first, 1e-6f)
        assertEquals(0.2f, spans[1].second, 1e-6f)
    }

    @Test
    fun awakeAndWakeAreAliases() {
        // Row label "Awake" must catch both the "wake" and "Awake" segments (stageColorFor parity).
        val spans = stageRowSpans(ivs, "Awake", 3600.0)
        assertEquals(2, spans.size)
        assertEquals(0.0f, spans[0].first, 1e-6f)
        assertEquals(0.9f, spans[1].first, 1e-6f)
    }

    @Test
    fun matchIsCaseAndWhitespaceInsensitive() {
        assertEquals("deep", canonicalStage("  Deep "))
        assertEquals("awake", canonicalStage("WAKE"))
        assertEquals("awake", canonicalStage("Awake"))
        assertEquals("rem", canonicalStage("REM"))
        assertEquals(1, stageRowSpans(ivs, "DEEP", 3600.0).size)
    }

    @Test
    fun absentStageOrDegenerateSpanIsEmpty() {
        assertTrue(stageRowSpans(ivs, "REM", 3600.0).isEmpty())
        assertTrue(stageRowSpans(ivs, "Deep", 0.0).isEmpty())
    }
}
