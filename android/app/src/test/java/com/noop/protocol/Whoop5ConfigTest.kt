package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Byte-parity tests for the WHOOP 5/MG R22 deep-data enable sequence. The golden frame is shared
 * verbatim with the macOS/iOS `Whoop5ConfigTests` and is the exact output of judes.club's documented
 * frame-builder for `enable_r22_packets` at seq=1 — so a mismatch here means Android and Apple would
 * write different bytes to the strap. (#174)
 */
class Whoop5ConfigTest {

    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

    @Test
    fun enableR22PacketsGoldenFrame() {
        val frame = Whoop5Config.frame(Whoop5Config.enableR22Sequence[0], seq = 1)
        // Identical to the macOS/iOS golden frame: header aa 01 30 00 00 01, CRC16 eb11, inner
        // [0x23,0x01,0x78,0x01] + "enable_r22_packets" NUL-padded to 32 + value '2' (0x32) + 7 zeros,
        // then CRC32 d2eeb0b7.
        val expected =
            "aa0130000001eb1123017801656e61626c655f7232325f7061636b65747300000000000000000000000000003200000000000000d2eeb0b7"
        assertEquals(expected, frame.hex())
    }

    @Test
    fun sequenceIsSixteenFlagsWithExpectedValues() {
        val seq = Whoop5Config.enableR22Sequence
        assertEquals(16, seq.size)
        assertEquals("enable_r22_packets", seq[0].name)
        assertEquals(0x32, seq[0].value)
        // v4 and the passive-strap-fit flag are the only '1' (0x31) values in the documented set.
        assertEquals(0x31, seq.first { it.name == "enable_r22_v4_packets" }.value)
        assertEquals(0x31, seq.first { it.name == "enable_passive_strap_fit_gen5" }.value)
        // #103: the 16th flag `enable_sig12` (value '2') was seen in a real on-strap capture, appended
        // after the 15 judes.club-documented flags. Mirror of the Swift Whoop5ConfigTests guard.
        assertEquals("enable_sig12", seq.last().name)
        assertEquals(0x32, seq.last().value)
    }

    @Test
    fun payloadBodyIsAsciiNameNulPaddedWithValueAt32() {
        val body = Whoop5Config.payloadBody("enable_r22_packets", 0x32)
        assertEquals(40, body.size)
        assertEquals("enable_r22_packets", String(body.copyOfRange(0, 18), Charsets.US_ASCII))
        for (i in 18 until 32) assertEquals(0, body[i].toInt())
        assertEquals(0x32, body[32].toInt() and 0xFF)
        for (i in 33 until 40) assertEquals(0, body[i].toInt())
    }
}
