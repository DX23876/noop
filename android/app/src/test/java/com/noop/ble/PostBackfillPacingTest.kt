package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PostBackfillPacingTest {
    @Test
    fun waitsWhileChunksKeepArriving() {
        assertTrue(PostBackfillPacing.keepWaiting(nowMs = 60_000, waitStartedMs = 0, lastChunkMs = 59_500))
    }

    @Test
    fun startsOnceTheChunksHaveStopped() {
        assertFalse(PostBackfillPacing.keepWaiting(nowMs = 60_000, waitStartedMs = 0,
                                                   lastChunkMs = 60_000 - PostBackfillPacing.QUIET_MS))
    }

    @Test
    fun aBacklogThatNeverStopsStillGetsAPass() {
        val now = PostBackfillPacing.MAX_WAIT_MS
        assertFalse(PostBackfillPacing.keepWaiting(nowMs = now, waitStartedMs = 0, lastChunkMs = now))
    }
}
