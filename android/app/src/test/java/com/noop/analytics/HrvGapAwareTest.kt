package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Gap-aware RMSSD/pNN50 (R-R optimization #1).
 *
 * When cleaning drops a beat (out-of-range or ectopic), its two neighbours become adjacent in the
 * cleaned list. The plain successive-difference RMSSD then counts the difference ACROSS that splice as
 * a real beat-to-beat delta, and because RMSSD squares each delta one splice can dominate the whole
 * window and bias RMSSD high. These tests prove:
 *   1. on a series with no drops the gap-aware result is identical to the plain result (no regression);
 *   2. a beat dropped in the MIDDLE no longer splices its neighbours into a spurious delta;
 *   3. the contiguity flags mark exactly the splice position;
 *   4. drops only at the END leave every survivor contiguous (the shape the existing gate tests use).
 */
class HrvGapAwareTest {

    // 1. No drops -> gap-aware equals plain, byte for byte.
    @Test
    fun cleanSeriesIsUnchanged() {
        val rr = (0 until 30).map { 800.0 + (it % 5) * 20.0 } // 800..880, all in range, non-ectopic
        val clean = HrvAnalyzer.cleanRR(rr)
        assertEquals("fixture must have no drops", rr.size, clean.size)

        val cleaned = HrvAnalyzer.cleanRRGapAware(rr)
        assertEquals(clean, cleaned.nn)
        assertTrue("no drops -> every survivor contiguous", cleaned.contiguous.drop(1).all { it })

        val plain = HrvAnalyzer.rmssdRaw(clean)!!
        val gapAware = HrvAnalyzer.analyzeRaw(rr).rmssd!!
        assertEquals(plain, gapAware, 1e-9)
    }

    // 2. A dropped middle beat must not splice its neighbours (the core fix).
    @Test
    fun midSeriesDropDoesNotSplice() {
        // 12x1000, one out-of-range 5000 (dropped by the range filter), 12x1100. The two 1000/1100 runs
        // stay within 20% of each other so the ectopic filter keeps them; only the 5000 is removed.
        val rr = List(12) { 1000.0 } + listOf(5000.0) + List(12) { 1100.0 }

        val result = HrvAnalyzer.analyzeRaw(rr)
        assertEquals(25, result.nInput)
        assertEquals(24, result.nClean)
        // Every kept successive difference is zero (within each flat run); the only nonzero delta is the
        // 1000->1100 step across the removed beat, which is skipped -> RMSSD and pNN50 are 0.
        assertNotNull(result.rmssd)
        assertEquals(0.0, result.rmssd!!, 1e-9)
        assertEquals(0.0, result.pnn50!!, 1e-9)

        // The plain (splicing) RMSSD over the SAME cleaned beats is clearly nonzero: proves divergence.
        val plainSpliced = HrvAnalyzer.rmssdRaw(HrvAnalyzer.cleanRR(rr))!!
        assertTrue("plain RMSSD splices the 100 ms jump: $plainSpliced", plainSpliced > 10.0)
    }

    // 3. The contiguity flag is false only at the splice.
    @Test
    fun contiguityFlagMarksTheSplice() {
        val rr = List(3) { 600.0 } + listOf(5000.0) + List(3) { 600.0 }
        val cleaned = HrvAnalyzer.cleanRRGapAware(rr)
        assertEquals(HrvAnalyzer.cleanRR(rr), cleaned.nn)
        assertEquals(List(6) { 600.0 }, cleaned.nn)
        // Survivors 0,1,2 then 4,5,6 in the source: the boundary between the 3rd and 4th is a splice.
        assertEquals(listOf(false, true, true, false, true, true), cleaned.contiguous)
    }

    // 4. Primitive: a spliced pair is excluded from the mean of squared differences.
    @Test
    fun rmssdGapAwarePrimitiveSkipsSplice() {
        val nn = listOf(500.0, 500.0, 1000.0, 1000.0)
        val contiguous = listOf(false, true, false, true) // index 2 straddles a removed beat
        assertEquals(0.0, HrvAnalyzer.rmssdGapAware(nn, contiguous)!!, 1e-9)
        // Same values with the plain estimator DO count the 500 ms splice.
        assertTrue(HrvAnalyzer.rmssdRaw(nn)!! > 100.0)

        assertEquals(0.0, HrvAnalyzer.pnn50GapAware(nn, contiguous)!!, 1e-9)
    }

    // 5. End-only drops keep every survivor contiguous (matches the #585 gate-test fixtures).
    @Test
    fun endDropsKeepAllContiguous() {
        val rr = List(24) { 800.0 } + List(6) { 100.0 } // 100 ms tail is out of range
        val cleaned = HrvAnalyzer.cleanRRGapAware(rr)
        assertEquals(24, cleaned.nn.size)
        assertFalse(cleaned.contiguous[0])
        assertTrue("no interior gap", cleaned.contiguous.drop(1).all { it })
        assertEquals(HrvAnalyzer.rmssdRaw(cleaned.nn), HrvAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous))
    }

    // 6. Boundary cases: empty, all-dropped, series shorter than the ectopic window, single survivor,
    //    and a two-beat pair that straddles a gap (zero valid pairs).
    @Test
    fun boundaryCases() {
        val empty = HrvAnalyzer.cleanRRGapAware(emptyList())
        assertTrue(empty.nn.isEmpty() && empty.contiguous.isEmpty())
        assertNull(HrvAnalyzer.rmssdGapAware(empty.nn, empty.contiguous))
        assertNull(HrvAnalyzer.pnn50GapAware(empty.nn, empty.contiguous))

        val allDropped = HrvAnalyzer.cleanRRGapAware(List(10) { 5000.0 }) // all out of range
        assertTrue(allDropped.nn.isEmpty())
        assertNull(HrvAnalyzer.rmssdGapAware(allDropped.nn, allDropped.contiguous))

        // Series shorter than the ectopic window is kept verbatim, matching cleanRR.
        val tiny = listOf(800.0, 810.0)
        val tinyClean = HrvAnalyzer.cleanRRGapAware(tiny)
        assertEquals(HrvAnalyzer.cleanRR(tiny), tinyClean.nn)
        assertEquals(listOf(false, true), tinyClean.contiguous)

        // One survivor between two dropped beats: no successive pair, null RMSSD.
        val single = HrvAnalyzer.cleanRRGapAware(listOf(5000.0, 800.0, 5000.0))
        assertEquals(listOf(800.0), single.nn)
        assertNull(HrvAnalyzer.rmssdGapAware(single.nn, single.contiguous))

        // Two survivors whose only pair straddles a gap: zero valid pairs, null.
        assertNull(HrvAnalyzer.rmssdGapAware(listOf(600.0, 900.0), listOf(false, false)))
        assertNull(HrvAnalyzer.pnn50GapAware(listOf(600.0, 900.0), listOf(false, false)))
    }

    // 7. Mismatched-length inputs fail fast rather than silently miscounting.
    @Test(expected = IllegalArgumentException::class)
    fun mismatchedLengthThrows() {
        HrvAnalyzer.rmssdGapAware(listOf(600.0, 900.0), listOf(true))
    }
}
