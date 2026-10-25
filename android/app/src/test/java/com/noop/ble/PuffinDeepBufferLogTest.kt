package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [PuffinDeepBufferLog] — the pure predicates + inline-IMU summary behind the durable high-rate
 * deep-buffer log (#423). Kotlin twin of the Swift PuffinDeepBufferLogTests. BLE delivery can't be
 * unit-tested, but the offset-8 + size gate CAN be, so a frame-shape change can't silently stop the
 * research log filling.
 */
class PuffinDeepBufferLogTest {

    @Test
    fun acceptsBigType2FAtOffset8() {
        val f = ByteArray(2140).also { it[8] = 0x2F.toByte() }   // the 2140-B high-rate buffer
        assertTrue(PuffinDeepBufferLog.isDeepBuffer(f))
        val g = ByteArray(1244).also { it[8] = 0x2F.toByte() }   // the 1244-B high-rate buffer
        assertTrue(PuffinDeepBufferLog.isDeepBuffer(g))
    }

    @Test
    fun rejectsSmallType2FRecord() {
        // The ~124-B type-0x2F frame is the 1 Hz rollup NOOP already decodes — below the size gate.
        val f = ByteArray(124).also { it[8] = 0x2F.toByte() }
        assertFalse(PuffinDeepBufferLog.isDeepBuffer(f))
    }

    @Test
    fun rejectsOtherTypesEvenWhenBig() {
        // Big frames of other inner types must never be treated as a deep buffer.
        for (t in listOf(0x28, 0x24, 0x30, 0x31, 0x32, 48)) {
            val f = ByteArray(2140).also { it[8] = t.toByte() }
            assertFalse("type $t must not be a deep buffer", PuffinDeepBufferLog.isDeepBuffer(f))
        }
    }

    @Test
    fun rejectsTooShortToIndexOffset8() {
        for (n in 0..8) {
            assertFalse(PuffinDeepBufferLog.isDeepBuffer(ByteArray(n) { 0x2F.toByte() }))
        }
    }

    /** A well-formed 1244-B 6-axis IMU buffer (Whoop5RawImu layout): countA/countB = 100, gravity on Z,
     *  and an X channel that alternates 800/0 so the decoded accel MAGNITUDE varies (non-zero AC energy
     *  so the feature extractor exercises its cadence path and stays finite). */
    private fun imuBuffer(): ByteArray {
        val f = ByteArray(1244)
        f[8] = 0x2F.toByte()
        f[24] = 100.toByte()         // countA (u16 LE) — Whoop5RawImu.decode requires == 100
        f[630] = 100.toByte()        // countB (u16 LE)
        fun put(off: Int, i: Int, v: Int) {
            f[off + 2 * i] = (v and 0xFF).toByte()
            f[off + 2 * i + 1] = ((v shr 8) and 0xFF).toByte()
        }
        for (i in 0 until 100) {
            put(28, i, if (i % 2 == 0) 800 else 0)   // ax @28  — magnitude actually varies
            put(428, i, 4096)                         // az @428 — ~1 g
        }
        return f
    }

    @Test
    fun emitsInlineDecodedImuFieldForImuBuffer() {
        val field = PuffinDeepBufferLog.decodedImuField(imuBuffer())
        assertTrue("a 1244-B IMU buffer must emit an inline summary", field.startsWith(",\"imu\":{"))
        assertTrue("summary carries the 100 decoded samples", field.contains("\"sampleCount\":100"))
        assertTrue("summary carries the activity features", field.contains("accelEnergyG"))
    }

    @Test
    fun noImuFieldForOpticalOrUndecodableBuffers() {
        // The 2140-B optical buffer is a different, still-undecoded layout — no IMU summary.
        val optical = ByteArray(2140).also { it[8] = 0x2F.toByte() }
        assertEquals("", PuffinDeepBufferLog.decodedImuField(optical))
        // A 1244-length frame whose count fields aren't 100 fails decode → field omitted, never a throw.
        val bogus = ByteArray(1244).also { it[8] = 0x2F.toByte() }
        assertEquals("", PuffinDeepBufferLog.decodedImuField(bogus))
    }
}
