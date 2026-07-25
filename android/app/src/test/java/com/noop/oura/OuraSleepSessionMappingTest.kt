package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Kotlin twin of Swift `OuraSleepSessionMappingTests`. The `stagesJson` byte string is asserted verbatim
 * so both platforms stay on the cross-platform stored-value contract (byte-identical segment JSON).
 */
class OuraSleepSessionMappingTest {

    // A tiny anchored sequence: deep,deep,light,rem,awake at 30 s epochs from t0.
    private fun codes(t0: Long): List<Pair<Long, OuraSleepStage>> = listOf(
        t0 to OuraSleepStage.DEEP,
        t0 + 30 to OuraSleepStage.DEEP,
        t0 + 60 to OuraSleepStage.LIGHT,
        t0 + 90 to OuraSleepStage.REM,
        t0 + 120 to OuraSleepStage.AWAKE,
    )

    @Test fun emptySequenceYieldsNoSession() {
        assertNull(OuraSleepSessionMapping.session(emptyList()))
    }

    @Test fun boundsAreFirstTsToLastTsPlusEpoch() {
        val t0 = 1_700_000_000L
        val s = OuraSleepSessionMapping.session(codes(t0))!!
        assertEquals(t0, s.startTs)
        assertEquals(t0 + 150, s.endTs)   // last code ts (t0+120) + one 30 s epoch
    }

    @Test fun adjacentEqualStagesMergeIntoOneSegment() {
        val t0 = 1_700_000_000L
        val s = OuraSleepSessionMapping.session(codes(t0))!!
        val expected = "[" +
            "{\"start\":$t0,\"end\":${t0 + 60},\"stage\":\"deep\"}," +
            "{\"start\":${t0 + 60},\"end\":${t0 + 90},\"stage\":\"light\"}," +
            "{\"start\":${t0 + 90},\"end\":${t0 + 120},\"stage\":\"rem\"}," +
            "{\"start\":${t0 + 120},\"end\":${t0 + 150},\"stage\":\"wake\"}" +
        "]"
        assertEquals(expected, s.stagesJson)
    }

    @Test fun efficiencyIsAsleepOverInBed() {
        val t0 = 1_700_000_000L
        val s = OuraSleepSessionMapping.session(codes(t0))!!
        // 4 asleep epochs (deep,deep,light,rem) + 1 awake → 4/5.
        assertEquals(0.8, s.efficiency!!, 1e-9)
    }

    @Test fun allAwakeIsZeroEfficiencyNotNull() {
        val t0 = 1_700_000_000L
        val s = OuraSleepSessionMapping.session(
            listOf(t0 to OuraSleepStage.AWAKE, t0 + 30 to OuraSleepStage.AWAKE))!!
        assertEquals(0.0, s.efficiency!!, 1e-9)
        assertEquals("[{\"start\":$t0,\"end\":${t0 + 60},\"stage\":\"wake\"}]", s.stagesJson)
    }

    @Test fun stageTokensMatchOnDeviceStagerConvention() {
        assertEquals("deep", OuraSleepSessionMapping.token(OuraSleepStage.DEEP))
        assertEquals("light", OuraSleepSessionMapping.token(OuraSleepStage.LIGHT))
        assertEquals("rem", OuraSleepSessionMapping.token(OuraSleepStage.REM))
        assertEquals("wake", OuraSleepSessionMapping.token(OuraSleepStage.AWAKE))   // awake persists as "wake"
    }
}
