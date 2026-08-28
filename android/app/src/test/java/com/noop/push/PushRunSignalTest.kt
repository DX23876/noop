package com.noop.push

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PushRunSignalTest {
    @Test fun ownerCoalescesRunningAndBackoffTriggersAndLateFinishCannotClearSuccessor() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()

        assertTrue(PushRunSignal.reserve(prefs, "a"))
        PushRunSignal.begin(prefs, "a")
        assertFalse(PushRunSignal.reserve(prefs, "b"))
        assertTrue(PushRunSignal.finish(prefs, "a", willRetry = false))

        // A successful owner is released; its caller can enqueue a fresh, non-backoff continuation.
        assertTrue(PushRunSignal.reserve(prefs, "b"))
        assertFalse(PushRunSignal.finish(prefs, "a", willRetry = false))
        assertFalse(PushRunSignal.reserve(prefs, "c"))

        PushRunSignal.begin(prefs, "b")
        assertTrue(PushRunSignal.finish(prefs, "b", willRetry = true))
        assertFalse(PushRunSignal.reserve(prefs, "must-coalesce"))
    }

    @Test fun abandonedPreEnqueueReservationExpiresButBackoffOwnerDoesNot() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        assertTrue(PushRunSignal.reserve(prefs, "abandoned", now = 1_000L))
        assertFalse(PushRunSignal.reserve(prefs, "too-soon", now = 120_999L))
        assertTrue(PushRunSignal.reserve(prefs, "replacement", now = 121_000L))

        PushRunSignal.begin(prefs, "replacement")
        PushRunSignal.finish(prefs, "replacement", willRetry = true)
        assertFalse(PushRunSignal.reserve(prefs, "must-coalesce", now = Long.MAX_VALUE))
    }

    @Test fun settlementSeesPendingBeforeStatusAndReleasesOwnerAfterStatus() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        assertTrue(PushRunSignal.reserve(prefs, "worker"))
        PushRunSignal.begin(prefs, "worker")
        assertFalse(PushRunSignal.reserve(prefs, "offload"))
        var statusSawPending: Boolean? = null

        val settlement = PushRunSignal.settle(prefs, "worker", willRetry = false) { pending ->
            statusSawPending = pending
        }

        assertTrue(settlement.owned)
        assertTrue(settlement.pending)
        assertTrue(statusSawPending == true)
        assertTrue(PushRunSignal.reserve(prefs, "successor"))
    }

    @Test fun failedReservationReleaseReportsCoalescedPendingExactlyOnce() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        assertTrue(PushRunSignal.reserve(prefs, "enqueue"))
        assertFalse(PushRunSignal.reserve(prefs, "trigger"))

        assertTrue(PushRunSignal.releaseReservation(prefs, "enqueue"))
        assertFalse(PushRunSignal.releaseReservation(prefs, "enqueue"))
        assertTrue(PushRunSignal.reserve(prefs, "retry"))
    }

    @Test fun asyncEnqueueFailureArbitratesStatusBeforeReleaseAndPreservesPendingForRequeue() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        assertTrue(PushRunSignal.reserve(prefs, "failed-enqueue"))
        assertFalse(PushRunSignal.reserve(prefs, "coalesced-trigger"))
        var failureWritten = false

        val pending = PushRunSignal.releaseReservation(prefs, "failed-enqueue") {
            if (!it) failureWritten = true
        }

        assertTrue(pending)
        assertFalse(failureWritten)
        assertTrue(PushRunSignal.reserve(prefs, "requeued-owner"))
    }
}
