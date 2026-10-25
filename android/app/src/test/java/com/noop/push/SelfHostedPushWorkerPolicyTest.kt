package com.noop.push

import androidx.work.ListenableWorker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SelfHostedPushWorkerPolicyTest {
    @Test fun pushNetworkGateHonorsWifiOnlyPreference() {
        assertTrue(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = true, isUnmetered = true))
        assertFalse(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = true, isUnmetered = false))
        assertFalse(isPushNetworkAvailable(wifiOnly = true, isConnected = true, isWifi = false, isUnmetered = true))
        assertTrue(isPushNetworkAvailable(wifiOnly = false, isConnected = true, isWifi = false, isUnmetered = false))
        assertFalse(isPushNetworkAvailable(wifiOnly = false, isConnected = false, isWifi = false, isUnmetered = false))
    }

    @Test fun retryableFailureKeepsFailingDeviceIndex() {
        assertEquals(2, persistedDeviceIndex(startDeviceIndex = 2, nextDeviceIndex = 3, retryableFailure = true))
    }

    @Test fun successfulSliceAdvancesDeviceIndex() {
        assertEquals(3, persistedDeviceIndex(startDeviceIndex = 2, nextDeviceIndex = 3, retryableFailure = false))
    }

    @Test fun genuineFailureRetryIsBoundedOnTheSameWorkRequestAttemptCount() {
        assertTrue(shouldRetryPush(0))
        assertTrue(shouldRetryPush(PUSH_MAX_ATTEMPTS - 2))
        assertFalse(shouldRetryPush(PUSH_MAX_ATTEMPTS - 1))
    }

    @Test fun scheduledPendingSuccessorIsNotBlockedByCurrentTerminalFailure() {
        val result = resultAfterScheduledContinuation(ListenableWorker.Result.failure(), scheduled = true)
        assertTrue(result is ListenableWorker.Result.Success)
    }

    @Test fun enqueueFailureCannotWriteTerminalStatusWhenSuccessorAlreadyOwnsSignal() {
        assertTrue(successorOwnsEnqueueFailure(currentRequestCouldReserve = false))
        assertFalse(successorOwnsEnqueueFailure(currentRequestCouldReserve = true))
    }

    @Test fun triggerAfterReacquireStillSchedulesSuccessorAtTerminalAttempt() {
        assertTrue(shouldScheduleLatePendingSuccessor(willRetry = false, settlementPending = true))
        assertFalse(shouldScheduleLatePendingSuccessor(willRetry = true, settlementPending = true))
        assertFalse(shouldScheduleLatePendingSuccessor(willRetry = false, settlementPending = false))
    }
}
