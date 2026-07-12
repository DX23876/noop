package com.noop.analytics

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #319: the #277 V2-default promotion applies to WHOOP 5.0/MG only. WHOOP 4.0 always uses V1 — its sparse
 * motion makes V2 inflate the Rest restorative term AND defeat the H9 low-confidence guard, so a poor 4.0
 * night reads as a confident 85-100. Pins [IntelligenceEngine.sleepStagerV2ForFamily] (byte-parity twin of
 * Swift `IntelligenceEngine.sleepStagerV2(enabled:family:)`).
 */
class SleepV2FamilyGateTest {

    @Test
    fun `V2 is the default on 5MG, never on WHOOP 4`() {
        assertTrue("5.0/MG with the toggle on → V2",
            IntelligenceEngine.sleepStagerV2ForFamily(enabled = true, family = DeviceFamily.WHOOP5))
        assertFalse("WHOOP 4 → V1 even with the toggle on",
            IntelligenceEngine.sleepStagerV2ForFamily(enabled = true, family = DeviceFamily.WHOOP4))
    }

    @Test
    fun `an explicit-off toggle wins on both families`() {
        assertFalse(IntelligenceEngine.sleepStagerV2ForFamily(enabled = false, family = DeviceFamily.WHOOP5))
        assertFalse(IntelligenceEngine.sleepStagerV2ForFamily(enabled = false, family = DeviceFamily.WHOOP4))
    }
}
