package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The read-only feature-status diagnostic (Kotlin twin of Swift's OuraFeatureStatusTests): NOOP asks the
 * ring its SpO2 (0x04) / real_steps (0x0b) feature status with the SAME 0x20 read verb as dhr_read, decodes
 * the 0x21 reply, and logs it once. Must never enable anything (no 0x22 set-mode) nor disturb the live-HR
 * triplet.
 */
class OuraFeatureStatusTest {
    private val key: IntArray = IntArray(16) { it }

    @Test
    fun statusQueryCommandsAreReadOnly() {
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x20, 0x04), OuraCommands.spo2ReadStatus().bytes)
        assertArrayEquals(intArrayOf(0x2F, 0x02, 0x20, 0x0B), OuraCommands.realStepsReadStatus().bytes)
        // sub-op 0x20 is READ; the enable would be 0x22 — neither query may ever carry it.
        assertEquals(0x20, OuraCommands.spo2ReadStatus().bytes[2])
        assertEquals(0x20, OuraCommands.realStepsReadStatus().bytes[2])
    }

    @Test
    fun decodesTheFiveStatusBytes() {
        // The observed daytime-HR reply `2f 06 21 02 01 11 02 00` → sub-body `02 01 11 02 00`.
        val st = OuraDecoders.decodeFeatureStatus(intArrayOf(0x02, 0x01, 0x11, 0x02, 0x00))
        assertEquals(OuraFeatureStatus(0x02, 1, 0x11, 2, 0), st)
    }

    @Test
    fun shortBodyDecodesToNull() {
        assertNull(OuraDecoders.decodeFeatureStatus(intArrayOf(0x04, 0x01)))
        assertNull(OuraDecoders.decodeFeatureStatus(intArrayOf()))
    }

    @Test
    fun daytimeHRReadStillAdvancesTheTriplet() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        val frame = OuraSecureFrame(0x21, intArrayOf(0x02, 0x01, 0x11, 0x02, 0x00))
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(frame))
    }

    @Test
    fun spo2AndStepsReadsSurfaceFeatureStatus() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertEquals(
            OuraDriver.SecureRouting.FeatureStatus(OuraFeatureStatus(0x04, 0, 0, 0, 0)),
            d.handleSecureFrame(OuraSecureFrame(0x21, intArrayOf(0x04, 0, 0, 0, 0))),
        )
        assertEquals(
            OuraDriver.SecureRouting.FeatureStatus(OuraFeatureStatus(0x0B, 0, 0, 0, 0)),
            d.handleSecureFrame(OuraSecureFrame(0x21, intArrayOf(0x0B, 0, 0, 0, 0))),
        )
    }

    @Test
    fun undecodableDiagnosticReplyFallsBackToEnableAck() {
        // A too-short 0x21 (can't decode a feature) must not mis-route; it stays EnableAck so the triplet
        // never stalls on a malformed reply.
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = key)
        assertEquals(OuraDriver.SecureRouting.EnableAck, d.handleSecureFrame(OuraSecureFrame(0x21, intArrayOf(0x04))))
    }
}
