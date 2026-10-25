package com.noop.push

import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

class SelfHostedPushSchedulerTest {
    @Test fun workConstraintHonorsWifiOnlyPreference() {
        assertEquals(NetworkType.UNMETERED, requiredPushNetworkType(wifiOnly = true))
        assertEquals(NetworkType.CONNECTED, requiredPushNetworkType(wifiOnly = false))
    }

    @Test fun workIsSerializedAndBackoffMeetsWorkManagerMinimum() {
        assertEquals(ExistingWorkPolicy.REPLACE, SelfHostedPushScheduler.EXISTING_WORK_POLICY)
        assertEquals(ExistingWorkPolicy.APPEND_OR_REPLACE, SelfHostedPushScheduler.CONTINUATION_WORK_POLICY)
        assertTrue(SelfHostedPushScheduler.UNIQUE_WORK.isNotBlank())
        assertTrue(SelfHostedPushScheduler.BACKOFF_SECONDS >= 10)
    }

    @Test fun asyncEnqueueFailureCompletesReservationOnlyOnce() {
        var settlements = 0
        var requeues = 0
        val completion = PushEnqueueCompletion(
            settleFailure = { settlements += 1; true },
            requeuePending = { requeues += 1 },
        )

        assertTrue(completion.failure())
        assertFalse(completion.failure())
        assertFalse(completion.success())
        assertEquals(1, settlements)
        assertEquals(1, requeues)
    }

    @Test fun continuationAsyncFailureRequeuesItsCoalescedPendingTrigger() {
        var settlements = 0
        var requeues = 0
        val completion = continuationEnqueueCompletion(
            settleFailure = { settlements += 1; true },
            requeuePending = { requeues += 1 },
        )

        assertTrue(completion.failure())
        assertEquals(1, settlements)
        assertEquals(1, requeues)
    }
}
