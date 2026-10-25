package com.noop.ble

import com.noop.protocol.DeviceFamily
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Read-back parsing for the reject-archive retro-decode (#151, Android parity with the macOS
 * RawHistoryArchiveReplayTests). Verifies one archived JSONL line round-trips to the exact frame bytes
 * + family, and that malformed lines are skipped rather than crashing the replay.
 */
class RawHistoryArchiveTest {

    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    @Test fun parsesWhoop4V25Line() {
        // A real archived v25 record line, in the exact shape encodeLine() writes.
        val hex = "aa50000c2f190013390000140d2b6a4075010068a2010032fdbcfd98fdd3fdccfd47ffb00366064f073e06" +
            "c103d3016cffa2fc87fa2ffae5fdbe03140675060c0510012dff1bfec0018f3c500500010068dc8f44"
        val line = """{"capturedAtMs":1781200000000,"trim":70476,"family":"whoop4","frameHex":"$hex"}"""
        val (frame, family) = RawHistoryArchive.parseArchiveLine(line)!!
        assertEquals(DeviceFamily.WHOOP4, family)
        assertArrayEquals(bytes(hex), frame)
    }

    @Test fun parsesWhoop5Family() {
        val line = """{"capturedAtMs":1,"trim":2,"family":"whoop5","frameHex":"aabb"}"""
        assertEquals(DeviceFamily.WHOOP5, RawHistoryArchive.parseArchiveLine(line)!!.second)
    }

    @Test fun malformedLinesAreSkipped() {
        assertNull(RawHistoryArchive.parseArchiveLine("""{"family":"whoop4"}""")) // no frameHex
        assertNull(RawHistoryArchive.parseArchiveLine("""{"frameHex":"aabb"}"""))  // no family
        assertNull(RawHistoryArchive.parseArchiveLine("""{"family":"whoop4","frameHex":"abc"}""")) // odd hex
        assertNull(RawHistoryArchive.parseArchiveLine("not json at all"))
    }
}
