package com.noop.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Pins the pure 0x2A37 Heart Rate Measurement *encoder* used by [HrBroadcaster] when NOOP re-broadcasts
 * its live strap HR back out as a standard Bluetooth HR peripheral (so a treadmill / Zwift / Peloton can
 * read it). The encoder is the inverse of [StandardHeartRate.parse], so each case is round-tripped back
 * through the parser to prove the two agree byte-for-byte. No android.bluetooth is touched — [measurement]
 * is a pure function over the bpm.
 *
 * Faithful twin of StrandTests/HrBroadcasterEncodeTests.swift.
 */
class HrBroadcasterEncodeTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    // MARK: - u8 path (the normal case: every realistic bpm < 256)

    @Test
    fun u8FlagsAndValue() {
        assertArrayEquals(bytes(0x00, 72), HrBroadcaster.measurement(72))
        assertArrayEquals(bytes(0x00, 60), HrBroadcaster.measurement(60))
        assertArrayEquals(bytes(0x00, 0), HrBroadcaster.measurement(0))
    }

    @Test
    fun u8FlagBit0IsClearBelow256() {
        for (bpm in listOf(1, 40, 120, 200, 254)) {
            val m = HrBroadcaster.measurement(bpm)
            assertEquals("u8 payload is flags + one value byte", 2, m.size)
            assertEquals("bit0 must be clear for a u8 value", 0, m[0].toInt() and 0x01)
        }
    }

    // MARK: - u16 path (boundary: a value that won't fit in a byte)

    @Test
    fun u16AtBoundary() {
        // 255 still fits a u8.
        assertArrayEquals(bytes(0x00, 255), HrBroadcaster.measurement(255))
        // 256 needs u16: flags=0x01, little-endian 0x00,0x01.
        assertArrayEquals(bytes(0x01, 0x00, 0x01), HrBroadcaster.measurement(256))
    }

    @Test
    fun u16FlagAndLittleEndian() {
        // 320 = 0x0140 → flags=0x01, LE bytes 0x40,0x01.
        val m = HrBroadcaster.measurement(320)
        assertArrayEquals(bytes(0x01, 0x40, 0x01), m)
        assertEquals("bit0 set selects the u16 value", 1, m[0].toInt() and 0x01)
    }

    // MARK: - Clamping (untrusted / out-of-range input never overflows the encoding)

    @Test
    fun negativeClampsToZero() {
        assertArrayEquals(bytes(0x00, 0), HrBroadcaster.measurement(-5))
    }

    @Test
    fun hugeValueClampsToU16Max() {
        assertArrayEquals(bytes(0x01, 0xFF, 0xFF), HrBroadcaster.measurement(1_000_000))
    }

    // MARK: - Round-trip against the parser (the encoder is the parser's exact inverse)

    @Test
    fun roundTripThroughParser() {
        for (bpm in listOf(37, 55, 72, 100, 180, 254, 255, 256, 300)) {
            val encoded = HrBroadcaster.measurement(bpm)
            val parsed = StandardHeartRate.parse(encoded)
            assertNotNull("encoded $bpm must re-parse", parsed)
            assertEquals("encode→parse round trip must preserve $bpm", bpm, parsed!!.hr)
            assertEquals("NOOP broadcasts a plain HR with no R-R", 0, parsed.rr.size)
        }
    }
}
