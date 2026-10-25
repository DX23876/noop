package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Shared contract vectors for the Swift/Kotlin five-minute SDNN index. */
class HrvAnalyzerSdnnIndexTest {
    private fun rr(values: List<Int>, start: Long = 0L): List<RrInterval> =
        values.mapIndexed { i, value -> RrInterval("t", start + i, value) }

    @Test
    fun rejectsEmptySparseAndNonPositiveSegments() {
        assertNull(HrvAnalyzer.sdnnIndex(emptyList(), segmentSec = 100))
        assertNull(HrvAnalyzer.sdnnIndex(rr(List(19) { 800 }), segmentSec = 100))
        assertNull(HrvAnalyzer.sdnnIndex(rr(List(20) { 800 }), segmentSec = 0))
    }

    @Test
    fun oneQualifyingConstantSegmentIsZero() {
        assertEquals(0.0, HrvAnalyzer.sdnnIndex(rr(List(20) { 800 }), segmentSec = 100)!!, 0.0)
    }

    @Test
    fun oneSegmentMatchesSampleSdnn() {
        val values = List(20) { if (it % 2 == 0) 790 else 810 }
        assertEquals(10.25978352085154, HrvAnalyzer.sdnnIndex(rr(values), 100)!!, 1e-12)
    }

    @Test
    fun averagesQualifyingSegmentsAndUsesInclusiveBoundaries() {
        val first = List(20) { if (it % 2 == 0) 790 else 810 }
            .mapIndexed { i, value -> RrInterval("t", i.toLong(), value) }
        val boundary = List(20) { RrInterval("t", 100L + it, 800) }
        assertEquals(5.12989176042577, HrvAnalyzer.sdnnIndex(first + boundary, 100)!!, 1e-12)
    }

    @Test
    fun skipsSegmentsThatDoNotHaveTwentyCleanIntervals() {
        val rejected = List(19) { RrInterval("t", it.toLong(), 800) } +
            RrInterval("t", 19L, 2_001)
        val qualifying = List(20) { RrInterval("t", 100L + it, 800) }
        assertEquals(0.0, HrvAnalyzer.sdnnIndex(rejected + qualifying, 100)!!, 0.0)
        assertNull(HrvAnalyzer.sdnnIndex(rejected, 100))
    }

    @Test
    fun stripsInterSegmentDrift() {
        val values = buildList {
            repeat(50) { add(if (it % 2 == 0) 795 else 805) }
            repeat(50) { add(if (it % 2 == 0) 895 else 905) }
            repeat(50) { add(if (it % 2 == 0) 995 else 1005) }
        }
        val index = HrvAnalyzer.sdnnIndex(rr(values), segmentSec = 50)!!
        assertEquals(5.050762722761053, index, 1e-12)
        assertTrue(HrvAnalyzer.analyzeRaw(values.map(Int::toDouble)).sdnn!! > 50.0)
    }
}
