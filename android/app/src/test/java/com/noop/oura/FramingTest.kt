package com.noop.oura

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Framing tests: outer command/response frames, the 0x2F secure-session sub-frame, and the TLV
 * inner-record parse — open_oura's ONE-packet-per-notification model (lenient `len`, no buffering,
 * no multi-record loop, no byte-drop resync). Kotlin twin of the Swift FramingTests.swift.
 *
 * PARITY NOTE: every fixture hex string here is byte-for-byte identical to the Swift FramingTests
 * fixtures, so the same wire bytes parse + reassemble to the same records across both ports.
 */
class FramingTest {
    private fun bytes(s: String) = OuraTestHex.bytes(s)

    // MARK: - Outer frame

    @Test
    fun testParseOuterFrame() {
        // 0d 06 <6 body bytes> (a battery response shape).
        val f = OuraFraming.parseOuterFrame(bytes("0d06570000003c0f"))
        assertEquals(0x0D, f?.op)
        assertArrayEquals(bytes("570000003c0f"), f?.body)
        assertEquals(8, f?.totalLength)
    }

    @Test
    fun testParseOuterFrameShortReturnsNil() {
        // Declares 6 body bytes but only 2 present -> null (wait for more).
        assertNull(OuraFraming.parseOuterFrame(bytes("0d065700")))
    }

    @Test
    fun testMultipleOuterFramesInOneValue() {
        // 25 01 00  (SetAuthKey resp)  then  1d 01 00 (SetNotification resp).
        val frames = OuraFraming.parseOuterFrames(bytes("2501001d0100"))
        assertEquals(2, frames.size)
        assertEquals(0x25, frames[0].op)
        assertArrayEquals(intArrayOf(0x00), frames[0].body)
        assertEquals(0x1D, frames[1].op)
        assertArrayEquals(intArrayOf(0x00), frames[1].body)
    }

    // MARK: - GetBattery response (0x0D, s6.10)

    @Test
    fun testBatteryResponseOpIsRecognisedAsAnOuterFrame() {
        // 0d 06 <percent=57=87> <charging=00> <flag=00> <3 unknown> - the live path routes this op to the
        // battery decoder, never to the TLV record decoder (op 0x0D is below the event-tag range).
        val frames = OuraFraming.parseOuterFrames(bytes("0d06570000003c0f"))
        assertEquals(1, frames.size)
        assertEquals(OuraFraming.batteryResponseOp, frames[0].op)
        val battery = OuraDecoders.decodeBattery(frames[0].body)
        assertEquals(0x57, battery?.percent)   // 87%
    }

    // MARK: - GetEvents response (0x11, s5.2 — open_oura EventBatchSummary, #91 twin)

    @Test
    fun testParseGetEventsResponseMoreDataFollows() {
        // 11 08 <events=ff> <progress=00> <bytes_left:4LE=0x00145d39> <pad:2> (a real on-device body).
        val outer = OuraFraming.parseOuterFrame(bytes("1108ff00395d14000300"))
        assertEquals(OuraFraming.getEventsResponseOp, outer?.op)
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0xFF, summary?.eventsReceived)
        assertEquals(0x0014_5D39L, summary?.bytesLeft)
        assertEquals(true, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseBytesLeftZeroIsDone() {
        // bytes_left == 0 -> drain complete, even with a nonzero events count in body[0] (#91: body[0]
        // is a batch COUNT, not a status; bytes 2-5 are bytes_left, never a cursor).
        val outer = OuraFraming.parseOuterFrame(bytes("11081000000000000300"))
        val summary = OuraFraming.parseGetEventsResponse(outer!!.body)
        assertEquals(0x10, summary?.eventsReceived)
        assertEquals(0L, summary?.bytesLeft)
        assertEquals(false, summary?.moreData)
    }

    @Test
    fun testParseGetEventsResponseShortBodyReturnsNil() {
        assertNull(OuraFraming.parseGetEventsResponse(bytes("ff0012")))
    }

    // MARK: - SyncTime response (0x13, s5.4 [ringverse]) + anchor tick disambiguation

    @Test
    fun testParseSyncTimeResponse() {
        // ringverse example body: 4b ed a9 00 00 -> device_ts 0x00A9ED4B, status 0.
        val resp = OuraFraming.parseSyncTimeResponse(bytes("4beda90000"))
        assertEquals(0x00A9_ED4BL, resp?.deviceTimestamp)
        assertEquals(0, resp?.status)
        // Short body -> null, never a guessed timestamp.
        assertNull(OuraFraming.parseSyncTimeResponse(bytes("4beda900")))
    }

    @Test
    fun testSyncTimeAnchorCandidateResolvesUnit() {
        // The 2026-07-13 shape: cursor banked at 4_413_933; ~11 h later the ring's clock is ~4.81M
        // ticks. A raw-ticks response fits [cursor, cursor+7d] and the seconds x10 reading does not.
        assertEquals(4_810_000L, OuraDriver.syncTimeAnchorCandidate(4_810_000L, 4_413_933L))
        // A seconds-unit response (481_000 s = 4.81M ticks) only fits when multiplied x10.
        assertEquals(4_810_000L, OuraDriver.syncTimeAnchorCandidate(481_000L, 4_413_933L))
        // Below the cursor in both readings (ring reboot / stale value) -> null.
        assertNull(OuraDriver.syncTimeAnchorCandidate(100_000L, 4_413_933L))
        // Beyond cursor+7d in both readings -> null.
        assertNull(OuraDriver.syncTimeAnchorCandidate(40_000_000L, 4_413_933L))
        // A fresh/reset cursor gives no reference -> null (never guess on a full pull).
        assertNull(OuraDriver.syncTimeAnchorCandidate(4_810_000L, 0L))
        // Ambiguity guard: BOTH readings inside the window -> null.
        assertNull(OuraDriver.syncTimeAnchorCandidate(150_000L, 140_000L))
    }

    @Test
    fun testAdoptSyncTimeAnchorResolvesHistoryTimes() {
        val d = OuraDriver(ringGen = OuraRingGen.GEN3, authKey = null)
        val now = 1_784_000_000L                     // inside the 2020-2035 plausibility window
        assertNull("no anchor yet", d.unixSeconds(forRingTimestamp = 4_800_000L))
        assertTrue(d.adoptSyncTimeAnchor(ringTimestamp = 4_810_000L, unixSeconds = now))
        // A record 10_000 ticks (1000 s) before the anchor resolves to now - 1000.
        assertEquals(now - 1000L, d.unixSeconds(forRingTimestamp = 4_800_000L))
        // An implausible host epoch is refused (never anchors to a garbage clock).
        assertFalse(d.adoptSyncTimeAnchor(ringTimestamp = 4_810_000L, unixSeconds = 100L))
    }

    // MARK: - Secure-session sub-frame (0x2F)

    @Test
    fun testSecureFrameNonceResponse() {
        // Wire: 2f 10 2c <nonce:15>. Outer: op 0x2F, len 0x10 (16), body = 2c + 15 nonce bytes.
        val wire = bytes("2f102c0102030405060708090a0b0c0d0e0f")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        assertEquals(0x2F, outer.op)
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2C, secure.subop)
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), secure.subBody)
        // And the auth layer pulls the 15-byte nonce straight out.
        assertArrayEquals(bytes("0102030405060708090a0b0c0d0e0f"), OuraAuth.nonce(secure))
    }

    @Test
    fun testSecureFrameAuthStatus() {
        // 2f 02 2e 00 -> success.
        val wire = bytes("2f022e00")
        val outer = OuraFraming.parseOuterFrame(wire)!!
        val secure = OuraFraming.parseSecureFrame(outer)!!
        assertEquals(0x2E, secure.subop)
        assertEquals(OuraAuthStatus.SUCCESS, OuraAuth.authStatus(secure))
    }

    @Test
    fun testNonSecureFrameReturnsNilSecure() {
        val outer = OuraOuterFrame(op = 0x0D, body = intArrayOf(0x01))
        assertNull(OuraFraming.parseSecureFrame(outer))
    }

    // MARK: - TLV record parsing

    @Test
    fun testParseTLVRecord() {
        // 7b 06 <rt:4 LE 02000100> 03 ca  -> type 0x7B, rt 0x00010002, payload 03 ca.
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca"))
        assertEquals(0x7B, rec?.type)
        assertEquals(0x0001_0002L, rec?.ringTimestamp)
        assertEquals(0x0002, rec?.counter)
        assertEquals(0x0001, rec?.session)
        assertArrayEquals(bytes("03ca"), rec?.payload)
        assertEquals(8, rec?.totalLength)
    }

    @Test
    fun testTLVLenBelowFourIsRejected() {
        // len must be >= 4 to cover the 4 timestamp bytes; len=3 -> null (honest, no guess).
        assertNull(OuraFraming.parseRecord(intArrayOf(0x7B, 0x03, 0x00, 0x01, 0x02)))
    }

    // MARK: - Lenient TLV parse + one-packet-per-notification reassembler (open_oura Packet::parse,
    // twin of Swift dae3d7a4 — the phantom-storm fix)

    @Test
    fun testParseRecordTooBigLenUsesWhatArrived() {
        // len 0x10 (16) declared but only 4 payload bytes present: the lenient parse uses what
        // arrived instead of waiting for (and swallowing) the next notification.
        val rec = OuraFraming.parseRecord(bytes("7b100200010003ca0102"))
        assertEquals(0x7B, rec?.type)
        assertArrayEquals(bytes("03ca0102"), rec?.payload)
    }

    @Test
    fun testParseRecordTrailingBytesBeyondLenAreIgnored() {
        // len 0x06 but extra trailing bytes follow (BLE padding / an unpacked second frame): the
        // payload stops at the declared end; the tail is never minted into a phantom record.
        val rec = OuraFraming.parseRecord(bytes("7b060200010003ca" + "4e0602000100006c"))
        assertEquals(0x7B, rec?.type)
        assertArrayEquals(bytes("03ca"), rec?.payload)
    }

    @Test
    fun testFeedReturnsAtMostOneRecordPerNotification() {
        // Two records packed into one value: the one-packet model parses the FIRST leniently and
        // ignores the tail (the ring sends one packet per notification; a packed tail is padding).
        val r = OuraReassembler()
        val recs = r.feed(bytes("7b060200010003ca" + "4e0602000100006c"))
        assertEquals(1, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testFeedNeverBuffersAcrossNotifications() {
        // A truncated notification is dropped whole (nothing buffered), and the next notification is
        // parsed on its own — no cross-notification reassembly, so a garbled value can never corrupt
        // the following one (the phantom-storm failure mode).
        val full = bytes("7b060200010003ca")
        val r = OuraReassembler()
        assertTrue(r.feed(full.copyOfRange(0, 5)).isEmpty())
        assertEquals(0, r.bufferedByteCount)
        val recs = r.feed(full)
        assertEquals(1, recs.size)
        assertEquals(0x7B, recs[0].type)
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testFeedDropsUnusableNotificationWholeNoResync() {
        // A noise value (len < 4 / too short) yields nothing — never walked byte-by-byte for a
        // resync, never a type-0 garbage record.
        val r = OuraReassembler()
        assertTrue(r.feed(intArrayOf(0x00, 0x01, 0x02, 0x03, 0x01, 0x02)).isEmpty())
        assertTrue(r.feed(intArrayOf(0x00, 0x01) + bytes("4e0602000100006c")).isEmpty())
        assertEquals(0, r.bufferedByteCount)
    }

    @Test
    fun testResetIsANoOpWithNoBufferedState() {
        val r = OuraReassembler()
        assertTrue(r.feed(intArrayOf(0x7B, 0x06, 0x02)).isEmpty())   // below floor, nothing retained
        assertEquals(0, r.bufferedByteCount)
        r.reset()
        assertEquals(0, r.bufferedByteCount)
    }
}
