package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The trail the crash report carries (`CoreCallTrail`). Written after the out-of-memory report of
 * 2026-11-19, where the throwing frame was a 592-byte allocation inside an unrelated small call and
 * nothing in the report said what had filled the heap.
 */
class CoreCallTrailTest {

    @Before fun clean() = CoreCallTrail.clearForTest()

    @Test
    fun nothingCrossedMeansNoBlock() {
        assertNull(CoreCallTrail.report())
    }

    @Test
    fun theTrailKeepsTheNewestCallsAndDropsTheOldest() {
        for (i in 1..CoreCallTrail.KEEP + 3) CoreCallTrail.done("op$i", 10, 20, 1)
        val ops = CoreCallTrail.recent().map { it.op }
        assertEquals(CoreCallTrail.KEEP, ops.size)
        assertEquals("op${CoreCallTrail.KEEP + 3}", ops.first())
        assertTrue(ops.none { it == "op1" })
    }

    @Test
    fun aCallThatHasNotComeBackIsNamedAsSuch() {
        CoreCallTrail.begin("sql.query", 180)
        val report = CoreCallTrail.report()!!
        assertTrue(report, report.contains("in flight: sql.query args=180"))
    }

    @Test
    fun aFinishedCallSaysWhatCrossedAndHowLongAgo() {
        CoreCallTrail.done("sql.query", 180, 24_000_000, 820)
        val e = CoreCallTrail.recent().first()
        assertEquals("sql.query args=180 answer=24M 820 ms, 5000 ms ago",
                     CoreCallTrail.line(e, e.atMs + 5_000))
    }

    /** A null answer is not an empty one: the core said nothing, which is a different fact. */
    @Test
    fun aNullAnswerReadsAsNull() {
        CoreCallTrail.done("coach.today", 2, -1, 4)
        val e = CoreCallTrail.recent().first()
        assertTrue(CoreCallTrail.line(e, e.atMs).contains("answer=null"))
    }

    @Test
    fun sizesAreRoundedOnceTheyStopBeingReadable() {
        assertEquals("9999", CoreCallTrail.chars(9_999))
        assertEquals("24k", CoreCallTrail.chars(24_500))
        assertEquals("48M", CoreCallTrail.chars(48_000_000))
    }
}
