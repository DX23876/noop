package com.noop.oura

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Tier-B activity research-corpus JSONL line encoder. The line is asserted verbatim so the format is
 * pinned byte-for-byte AND stays interchangeable with the Swift `OuraActivityDumpLine` corpus (same key
 * order, same `met` formatting).
 */
class OuraActivityDumpLineTest {

    @Test
    fun encodesFixedShapeVerbatim() {
        val line = OuraActivityDumpLine.encode(
            deviceId = "oura-5C4C0BF8", ringTs = 5_691_839, utc = 1_783_400_728,
            iso = "2026-07-14T09:05:28Z", state = 23, secPerSample = 60,
            met = listOf(2.2, 1.5, 1.4),
        )
        assertEquals(
            "{\"schema\":1,\"deviceId\":\"oura-5C4C0BF8\",\"ringTs\":5691839," +
                "\"utc\":1783400728,\"iso\":\"2026-07-14T09:05:28Z\",\"state\":23," +
                "\"secPerSample\":60,\"met\":[2.2,1.5,1.4]}",
            line,
        )
    }

    @Test
    fun emptyMetIsEmptyArray() {
        val line = OuraActivityDumpLine.encode("d", 1, 2, "x", 0, 60, emptyList())
        assertTrue(line.endsWith("\"met\":[]}"))
    }

    @Test
    fun wholeAndMultiDigitMetMatchSwift() {
        // 3.0 / 4.3 / 12.8 format identically in Swift String(Double) and Kotlin Double.toString, so the
        // two platforms' corpora stay byte-identical across the MET range.
        val line = OuraActivityDumpLine.encode(
            "oura-ring", 100, 200, "2026-07-14T00:00:00Z", 148, 60, listOf(3.0, 4.3, 12.8),
        )
        assertTrue(line.contains("\"met\":[3.0,4.3,12.8]}"))
        assertTrue(line.contains("\"state\":148"))
        assertTrue(line.contains("\"schema\":${OuraActivityDumpLine.SCHEMA}"))
    }
}
