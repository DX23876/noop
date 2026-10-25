package com.noop.data

import com.noop.analytics.NapCandidate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-logic tests for [NapStore]'s id / dedup / retention contract (PR #569 reimpl). The
 * SharedPreferences + org.json I/O isn't unit-testable on plain JVM (org.json isn't mocked, matching the
 * CaffeineLog store), so the dedup + retention rules are exposed as pure functions and tested here.
 */
class NapStoreTest {

    private fun cand(start: Long, end: Long, meanHr: Int? = 55, conf: Double = 0.6) =
        NapCandidate(start = start, end = end, meanHr = meanHr, confidence = conf)

    @Test fun idFor_isStableForTheSameWindow() {
        assertEquals(NapStore.idFor(cand(100, 200)), NapStore.idFor(cand(100, 200, meanHr = 99)))
    }

    @Test fun idFor_differsForDifferentWindows() {
        assertFalse(NapStore.idFor(cand(100, 200)) == NapStore.idFor(cand(100, 201)))
    }

    @Test fun endTsOf_parsesTheEnd() {
        assertEquals(200L, NapStore.endTsOf(NapStore.idFor(cand(100, 200))))
    }

    @Test fun endTsOf_malformedIsNull() {
        assertNull(NapStore.endTsOf("not-an-id"))
        assertNull(NapStore.endTsOf("100|"))
        assertNull(NapStore.endTsOf("100"))
    }

    @Test fun shouldEnqueue_newWindowEnqueues() {
        assertTrue(NapStore.shouldEnqueue(cand(100, 200), emptySet(), emptySet()))
    }

    @Test fun shouldEnqueue_alreadyPendingDoesNot() {
        val c = cand(100, 200)
        assertFalse(NapStore.shouldEnqueue(c, setOf(NapStore.idFor(c)), emptySet()))
    }

    @Test fun shouldEnqueue_previouslyDismissedDoesNot() {
        val c = cand(100, 200)
        assertFalse(NapStore.shouldEnqueue(c, emptySet(), setOf(NapStore.idFor(c))))
    }

    @Test fun shouldEnqueue_differentWindowStillEnqueuesEvenWhenOthersPending() {
        val pending = setOf(NapStore.idFor(cand(100, 200)))
        assertTrue(NapStore.shouldEnqueue(cand(300, 400), pending, emptySet()))
    }

    @Test fun pruneDismissed_keepsFreshDropsStale() {
        val fresh = NapStore.idFor(cand(0, 10_000))
        val stale = NapStore.idFor(cand(0, 1_000))
        val kept = NapStore.pruneDismissed(setOf(fresh, stale), cutoff = 5_000)
        assertTrue(fresh in kept)
        assertFalse(stale in kept)
    }

    @Test fun pruneDismissed_dropsMalformedIds() {
        val good = NapStore.idFor(cand(0, 10_000))
        val kept = NapStore.pruneDismissed(setOf(good, "garbage", "5|"), cutoff = 1_000)
        assertEquals(setOf(good), kept)
    }

    @Test fun pruneDismissed_boundaryIsInclusive() {
        val onCutoff = NapStore.idFor(cand(0, 5_000))
        assertTrue(onCutoff in NapStore.pruneDismissed(setOf(onCutoff), cutoff = 5_000))
    }
}
