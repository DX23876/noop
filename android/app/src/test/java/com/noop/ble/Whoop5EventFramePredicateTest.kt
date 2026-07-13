package com.noop.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [WhoopBleClient.isWhoop5EventFrame] — the pure predicate behind the durable EVENT-frame log
 * (#103/#346). A reassembled WHOOP 5/MG frame carries its inner-record type at offset 8, and EVENT is
 * type 48 (0x30); the log keys on exactly that. BLE delivery itself can't be unit-tested, but this
 * offset-8 magic number CAN be, so a future frame-shape change can't silently break the capture (the
 * failure mode would otherwise be "the research log quietly stops filling"). Mirrors the family-aware
 * [Whoop5OffloadTest] which pins the sibling frame[8] index for `isOffloadFrame`. Twin of the Swift
 * `PuffinEventLogTests`.
 */
class Whoop5EventFramePredicateTest {

    @Test
    fun acceptsEventTypeAtOffset8() {
        val f = ByteArray(12)
        f[8] = 0x30 // EVENT (type 48)
        assertTrue(WhoopBleClient.isWhoop5EventFrame(f))
    }

    @Test
    fun rejectsNonEventTypes() {
        // Every other type byte seen at offset 8 on this path — live REALTIME(40) and the offload
        // record types (47/48-is-event/49/50, PUFFIN_METADATA 56) — must NOT be logged as an EVENT.
        for (t in intArrayOf(40, 47, 49, 50, 56, 0x2F, 0x24)) {
            val f = ByteArray(12)
            f[8] = t.toByte()
            assertFalse("type $t must not be treated as an EVENT frame",
                WhoopBleClient.isWhoop5EventFrame(f))
        }
    }

    @Test
    fun rejectsFramesTooShortToIndexOffset8() {
        // The inner-record type is at offset 8, so a frame with size <= 8 has no type byte to read;
        // the predicate must guard the index (no crash, no false positive).
        for (n in 0..8) {
            assertFalse("size $n is too short to be an EVENT frame",
                WhoopBleClient.isWhoop5EventFrame(ByteArray(n)))
        }
    }

    @Test
    fun boundaryExactlyNineBytesWithEventTypeIsAccepted() {
        // The smallest frame that can carry the offset-8 type byte: size 9 (indices 0..8).
        val f = ByteArray(9)
        f[8] = 0x30
        assertTrue(WhoopBleClient.isWhoop5EventFrame(f))
        // And size 8 (no index 8) is rejected even though it's one byte short.
        assertFalse(WhoopBleClient.isWhoop5EventFrame(ByteArray(8)))
    }
}
