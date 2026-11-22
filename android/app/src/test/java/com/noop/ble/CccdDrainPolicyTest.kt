package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure JVM coverage for the notify-subscribe drain rules, pinned against the tester log of 2026-11-22
 * (OPPO CPH2499, Android 17, WHOOP MG): twenty CLIENT_HELLO acks, fourteen confirmed fd4b0007
 * subscribes, five links with no offload at all.
 */
class CccdDrainPolicyTest {

    @Test
    fun fourCharacteristicsEachGetTheirOwnBudget() {
        // The 18:45 link: four characteristics, each failing. Per characteristic the eighth attempt is
        // the last one, and the ninth is refused — which is what a SHARED budget did after two.
        for (attempt in 0 until CccdDrainPolicy.MAX_RETRIES_PER_CHARACTERISTIC) {
            assertTrue("attempt $attempt should be allowed", CccdDrainPolicy.mayRetry(attempt))
        }
        assertFalse(CccdDrainPolicy.mayRetry(CccdDrainPolicy.MAX_RETRIES_PER_CHARACTERISTIC))
    }

    @Test
    fun theRetryDelayEscalatesAndThenStops() {
        assertEquals(60L, CccdDrainPolicy.retryDelayMs(0))
        assertEquals(60L, CccdDrainPolicy.retryDelayMs(1))
        assertEquals(120L, CccdDrainPolicy.retryDelayMs(2))
        assertEquals(480L, CccdDrainPolicy.retryDelayMs(8))
        // Capped, so a long run of failures cannot stretch one subscribe into minutes.
        assertEquals(480L, CccdDrainPolicy.retryDelayMs(99))
    }

    @Test
    fun theWholeBudgetForOneCharacteristicIsBoundedAndNotInstant() {
        val total = (1..CccdDrainPolicy.MAX_RETRIES_PER_CHARACTERISTIC)
            .sumOf { CccdDrainPolicy.retryDelayMs(it) }
        // The flat 60 ms budget spent all eight attempts in 480 ms across FOUR characteristics. One
        // characteristic alone now gets more than four times that long to clear.
        assertEquals(2_160L, total)
        assertTrue(total > 4 * 480L)
    }

    @Test
    fun aHandshakeNeedsSomewhereForTheOffloadToArrive() {
        assertFalse(CccdDrainPolicy.handshakeMayComplete(0))
        assertTrue(CccdDrainPolicy.handshakeMayComplete(1))
        assertTrue(CccdDrainPolicy.handshakeMayComplete(4))
    }

    @Test
    fun recoveryRedrainsOnceBouncesOnceAndThenStops() {
        assertEquals(CccdDrainPolicy.Recovery.REDRAIN, CccdDrainPolicy.recovery(0))
        assertEquals(CccdDrainPolicy.Recovery.BOUNCE, CccdDrainPolicy.recovery(1))
        assertEquals(CccdDrainPolicy.Recovery.GIVE_UP, CccdDrainPolicy.recovery(2))
        assertEquals(CccdDrainPolicy.Recovery.GIVE_UP, CccdDrainPolicy.recovery(7))
    }

    @Test
    fun anEmptyOffloadIsOnlyEvidenceWhenEveryChannelWasSubscribed() {
        assertTrue(CccdDrainPolicy.countsTowardEmptyStreak(confirmedNotifyChars = 4, totalNotifyChars = 4))
        assertFalse(CccdDrainPolicy.countsTowardEmptyStreak(confirmedNotifyChars = 3, totalNotifyChars = 4))
        assertFalse(CccdDrainPolicy.countsTowardEmptyStreak(confirmedNotifyChars = 0, totalNotifyChars = 4))
    }

    @Test
    fun theLinesNameTheEvidenceAndNotMoreThanThat() {
        assertTrue(CccdDrainPolicy.noConfirmedChannelsLine(4).contains("none of the 4 notify channels"))
        assertTrue(CccdDrainPolicy.writeTimedOutLine("fd4b0005").contains("fd4b0005"))
        assertTrue(CccdDrainPolicy.writeTimedOutLine("fd4b0005").contains("2000ms"))
        val notCharged = CccdDrainPolicy.emptyOffloadNotChargedLine(1, 4)
        assertTrue(notCharged.contains("only 1 of 4 notify"))
        // It must not claim the strap is at fault, which is the whole point of excluding it.
        assertFalse(notCharged.contains("experimental"))
    }
}
