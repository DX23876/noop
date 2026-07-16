package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reconnect DIRECT-vs-PASSIVE escalation (#313). PASSIVE (autoConnect=true) is correct + power-efficient
 * for a strap that's genuinely OUT OF RANGE, but it STALLS on a band the OS still holds ACL-connected
 * (co-resident with the official WHOOP app) — it never re-emits the advert/connection-complete autoConnect
 * waits for, so the keep-alive battery poll + offload freeze. #265 masked this only when a co-resident band
 * flapped through STATE_CONNECTED (zeroing the counter); a band that fails BEFORE STATE_CONNECTED for 3+
 * attempts hit the same stall. These pin [WhoopBleClient.passiveReconnectDecision] so the ACL-held → stay
 * DIRECT rule can't silently regress. The by-address ACL lookup itself needs a live BLE stack; the decision
 * is pure.
 */
class PassiveReconnectDecisionTest {

    @Test
    fun staysDirect_belowThreshold() {
        // Early attempts are always fast DIRECT (unchanged from the old `>= 3`).
        assertFalse(WhoopBleClient.passiveReconnectDecision(failedAttempts = 0, aclHeld = false))
        assertFalse(WhoopBleClient.passiveReconnectDecision(failedAttempts = 2, aclHeld = false))
    }

    @Test
    fun escalatesToPassive_atThreshold_whenOutOfRange() {
        // Genuinely out of range (not ACL-held): PASSIVE autoConnect is correct — reconnect once back
        // in range, no scan, power-efficient.
        assertTrue(WhoopBleClient.passiveReconnectDecision(failedAttempts = 3, aclHeld = false))
        assertTrue(WhoopBleClient.passiveReconnectDecision(failedAttempts = 9, aclHeld = false))
    }

    @Test
    fun staysDirect_whenAclHeld_evenPastThreshold() {
        // THE #313 fix: a co-resident/ACL-held band NEVER goes PASSIVE, no matter how high the count —
        // PASSIVE stalls it; only DIRECT recovers.
        assertFalse(WhoopBleClient.passiveReconnectDecision(failedAttempts = 3, aclHeld = true))
        assertFalse(WhoopBleClient.passiveReconnectDecision(failedAttempts = 50, aclHeld = true))
    }

    @Test
    fun thresholdIsConfigurable() {
        assertFalse(WhoopBleClient.passiveReconnectDecision(failedAttempts = 4, aclHeld = false, threshold = 5))
        assertTrue(WhoopBleClient.passiveReconnectDecision(failedAttempts = 5, aclHeld = false, threshold = 5))
    }
}
