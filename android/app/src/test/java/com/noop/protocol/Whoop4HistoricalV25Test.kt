package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * WHOOP 4.0 **v25** historical layout (issue #30) — the firmware layout NOOP couldn't decode ("no
 * motion data, so sleep can't be computed"). Three REAL v25 records (faklei, App 1.92, 2026-06-11),
 * 84 bytes each. Layout RE'd from 45 such records: `unix` @11 (u32 LE) and the DSP gravity vector
 * @73/75/77 as 3×i16 LE / 16384 (|gravity| ≈ 1 g). Mirrors the Swift Whoop4HistoricalV25Tests.
 */
class Whoop4HistoricalV25Test {
    private fun bytes(s: String): ByteArray =
        ByteArray(s.length / 2) { ((s[it * 2].digitToInt(16) shl 4) or s[it * 2 + 1].digitToInt(16)).toByte() }

    private val records = listOf(
        "aa50000c2f1900006800007dff2a6a20430900433103007e026502ba026c022eff70f996f879fad6fd8300d6017e0267027201be00290258030e05c507f00c030ead11cb15791500d2553c9003000000d6393716",
        "aa50000c2f1900016800007eff2a6a283e0900a0ad03007a0e880698018bfff5fb61eee9f2a7fa2bfe1af5fdf618fdf0f9c2fb0804510a14046a004dffd0ff6dfdddfd670183014e071a3f9003000000587bbabf",
        "aa50000c2f1900026800007fff2a6a38390900729103003608a2fd0104850d4f1bd21aa60f080d850edb116b0f160b7d063f06ab04d5041704a4045f04f003f5ffd7ff7efe73ffa8b2333e9003010000fa54e5e9",
    ).map { bytes(it) }

    @Test fun v25DecodesUnixAndGravity() {
        for (rec in records) {
            val p = decodeHistorical(rec, DeviceFamily.WHOOP4)
            assertNotNull("v25 record must decode (not rejected)", p)
            assertEquals(25, p!!["hist_version"])
            // Long, not Int: `unix` is an unsigned u32 carried in the unsigned domain so a post-2038
            // value cannot go negative on Kotlin's 32-bit Int (see `histU32`).
            val unix = p["unix"] as? Long
            assertNotNull(unix)
            assertTrue(unix!! > 1_781_000_000L)
            val gx = p["gravity_x"] as? Double
            assertNotNull("v25 must decode gravity (the sleep-staging input)", gx)
            val gy = (p["gravity_y"] as? Double) ?: 0.0
            val gz = (p["gravity_z"] as? Double) ?: 0.0
            val mag = sqrt(gx!! * gx + gy * gy + gz * gz)
            assertTrue("|gravity| ~1 g, got $mag", mag in 0.8..1.2)
        }
        // unix increments 1 Hz across the three.
        val ts = records.map { decodeHistorical(it, DeviceFamily.WHOOP4)!!["unix"] as Long }
        assertEquals(listOf(ts[0], ts[0] + 1, ts[0] + 2), ts)
    }

    @Test fun v25NotRejected() {
        assertTrue("v25 records carry gravity and must not be treated as undecodable",
            rejectedHistoricalRecords(records, DeviceFamily.WHOOP4).isEmpty())
    }

    @Test fun v25ProducesGravityStream() {
        val ref = (decodeHistorical(records[0], DeviceFamily.WHOOP4)!!["unix"] as Long).toInt()
        val streams = extractHistoricalStreams(records, deviceClockRef = ref, wallClockRef = ref)
        assertEquals(records.size, streams.gravity.size)
    }
}
