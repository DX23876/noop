package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class RawTimelineUnionTest {
    private fun rr(source: String, ts: Long, ms: Int, seq: Int = 0) =
        RrInterval(deviceId = source, ts = ts, rrMs = ms, seq = seq)

    @Test
    fun rrUnionIsOrderedAndActiveWinsExactBeatTie() {
        val active = listOf(rr("whoop-new", 102, 810), rr("whoop-new", 100, 800))
        val canonical = listOf(rr("my-whoop", 99, 790), rr("my-whoop", 100, 800), rr("my-whoop", 101, 805))

        val merged = WhoopRepository.mergeRrByIdentity(listOf(active, canonical))

        assertEquals(listOf(99L, 100L, 101L, 102L), merged.map { it.ts })
        assertEquals("whoop-new", merged.first { it.ts == 100L }.deviceId)
    }

    @Test
    fun rrUnionKeepsDistinctBeatsAtSameTimestamp() {
        val merged = WhoopRepository.mergeRrByIdentity(
            listOf(
                listOf(rr("whoop-new", 100, 800, seq = 0), rr("whoop-new", 100, 810, seq = 1)),
                listOf(rr("my-whoop", 100, 800, seq = 0)),
            ),
        )

        assertEquals(listOf(800, 810), merged.map { it.rrMs })
    }

    @Test
    fun rrSingleCanonicalSourceIsUnchanged() {
        val only = listOf(rr("my-whoop", 100, 800))
        assertSame(only, WhoopRepository.mergeRrByIdentity(listOf(only)))
    }

    @Test
    fun motionSourcesPreferSessionOwnerThenActiveAndCanonicalComputed() {
        assertEquals(
            listOf("whoop-old-noop", "whoop-new-noop", "my-whoop-noop"),
            WhoopRepository.motionSourceIdsFor("whoop-new", "whoop-old-noop"),
        )
        assertEquals(
            listOf("my-whoop-noop"),
            WhoopRepository.motionSourceIdsFor("my-whoop", "my-whoop"),
        )
    }
}
