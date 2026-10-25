package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** E-4: the history ack follows the core's durable write when the switch is on, and only then. */
class CoreShadowAckTest {
    @Test fun withTheSwitchOffTheAckIsSentAsBeforeWithoutAskingTheCore() {
        var asked = false
        assertTrue(CoreShadow.mayAck(confirms = false, coreRunning = false) { asked = true; false })
        assertFalse(asked)
    }

    @Test fun withTheSwitchOnTheAckWaitsForTheCoreToBankTheChunk() {
        assertTrue(CoreShadow.mayAck(confirms = true, coreRunning = true) { true })
        assertFalse(CoreShadow.mayAck(confirms = true, coreRunning = true) { false })
    }

    @Test fun withTheSwitchOnAndNoCoreTheAckIsHeld() {
        var asked = 0
        assertFalse(CoreShadow.mayAck(confirms = true, coreRunning = false) { asked++; true })
        assertEquals(0, asked)
    }
}
