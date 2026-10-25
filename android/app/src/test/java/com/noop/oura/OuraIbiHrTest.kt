package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Tests for deriving hrSample-shaped HR from banked IBI (#728). Twin of Swift OuraIbiHrTests. */
class OuraIbiHrTest {

    private fun ibi(rt: Long, ms: Int) = OuraIBI(ringTimestamp = rt, ibiMs = ms)

    @Test
    fun perRecordMedianHRGroupsByRingTime() {
        // rt=100: median(1000,1020,980)=1000 -> 60 bpm. rt=200: median(900,910)=905 -> 66 bpm.
        val hr = OuraIbiHr.perRecordMedianHR(
            listOf(ibi(100, 1000), ibi(100, 1020), ibi(100, 980), ibi(200, 900), ibi(200, 910)),
        )
        assertEquals(
            listOf(
                OuraHR(ringTimestamp = 100, bpm = 60, ibiMs = 1000),
                OuraHR(ringTimestamp = 200, bpm = 66, ibiMs = 905),
            ),
            hr,
        )
    }

    @Test
    fun sixBeatsOfOneRecordCollapseToOneRow() {
        val hr = OuraIbiHr.perRecordMedianHR((0 until 6).map { ibi(500, 1000 + it) })
        assertEquals(1, hr.size)
        assertEquals(500L, hr.first().ringTimestamp)
    }

    @Test
    fun outOfRangeIBIsExcludedFromMedian() {
        assertEquals(
            listOf(OuraHR(ringTimestamp = 1, bpm = 60, ibiMs = 1000)),
            OuraIbiHr.perRecordMedianHR(listOf(ibi(1, 100), ibi(1, 1000), ibi(1, 3000))),
        )
    }

    @Test
    fun recordWithNoInRangeBeatYieldsNothing() {
        assertTrue(OuraIbiHr.perRecordMedianHR(listOf(ibi(1, 100), ibi(1, 5000))).isEmpty())
    }

    @Test
    fun emptyInput() {
        assertTrue(OuraIbiHr.perRecordMedianHR(emptyList()).isEmpty())
    }

    @Test
    fun returnedOldestRingTimeFirst() {
        assertEquals(
            listOf(100L, 200L, 300L),
            OuraIbiHr.perRecordMedianHR(listOf(ibi(300, 1000), ibi(100, 1000), ibi(200, 1000)))
                .map { it.ringTimestamp },
        )
    }
}
