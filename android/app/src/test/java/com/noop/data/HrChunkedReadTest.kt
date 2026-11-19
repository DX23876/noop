package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `WhoopRepository.hrInChunks` must return exactly what one big read returns.
 *
 * The chunking exists to keep the bridge hand-over small (`CoreSql.maxRows`, the out-of-memory report of
 * 2026-11-19), and it is only allowed to do that if nobody can tell from the rows that it happened. The
 * statement orders ascending and its limit keeps the earliest rows, so this asserts against a plain
 * `take` over the same window.
 */
class HrChunkedReadTest {

    /** The store, as the statement reads it: ascending by timestamp, at most `limit` rows. */
    private fun rows(from: Long, to: Long, limit: Int, every: Long = 1L): List<HrSample> =
        generateSequence(0L) { it + 1 }
            .map { from + it * every }
            .takeWhile { it <= to }
            .take(limit)
            .map { HrSample("my-whoop", it, 60) }
            .toList()

    @Test
    fun chunkedReadingReturnsTheSameRowsAsOneRead() = runBlocking {
        val from = 1_000L
        val to = from + 90_000L
        var reads = 0
        val chunked = WhoopRepository.hrInChunks(from, to, limit = 200_000) { f, t, n ->
            reads++
            rows(f, t, n)
        }
        assertEquals(rows(from, to, 200_000), chunked)
        assertTrue("one read would not have chunked anything", reads > 1)
    }

    @Test
    fun theLimitStillCutsAtTheSameRow() = runBlocking {
        val from = 0L
        val limit = WhoopRepository.HR_CHUNK * 2 + 17
        val chunked = WhoopRepository.hrInChunks(from, 10_000_000L, limit) { f, t, n -> rows(f, t, n) }
        assertEquals(limit, chunked.size)
        assertEquals(rows(from, 10_000_000L, limit), chunked)
    }

    /** A sparse window ends early; the loop must not keep asking once a chunk comes back short. */
    @Test
    fun aWindowThatRunsOutStopsReading() = runBlocking {
        var reads = 0
        val chunked = WhoopRepository.hrInChunks(0L, 100_000L, limit = 200_000) { f, t, n ->
            reads++
            rows(f, t, n, every = 1_000L)
        }
        assertEquals(101, chunked.size)
        assertEquals(1, reads)
    }

    /** Under the chunk size nothing changes: one read, as before. */
    @Test
    fun aSmallReadIsStillOneRead() = runBlocking {
        var reads = 0
        WhoopRepository.hrInChunks(0L, 10_000L, limit = 2_000) { f, t, n -> reads++; rows(f, t, n) }
        assertEquals(1, reads)
    }
}
