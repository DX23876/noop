package com.noop.ble

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [WhoopBleClient.dataRangeNewestUnix] offset/future-date correctness (#451/#928/#1012).
 *
 * Regression fixtures are David's REAL WHOOP 4.0 GET_DATA_RANGE frames captured 2026-07-11: the newest
 * banked record is 2026-07-11 16:00 (unix 1_783_785_625) and it sits at BYTE OFFSET 8 — off the old
 * 4-byte-aligned-from-7 grid, so the old scan returned null and a stale FUTURE word stayed latched in
 * strapNewestTs, which #228 then used to skip the periodic offload → auto-sync stalled ~25 min.
 */
class DataRangeScanTest {

    private fun hex(s: String) = ByteArray(s.length / 2) {
        ((Character.digit(s[it * 2], 16) shl 4) + Character.digit(s[it * 2 + 1], 16)).toByte()
    }

    /** Little-endian u32 [value] written at [offset] into a [size]-byte frame (rest zero). */
    private fun frameWithU32(size: Int, offset: Int, value: Long): ByteArray {
        val b = ByteArray(size)
        for (k in 0..3) b[offset + k] = ((value shr (8 * k)) and 0xFF).toByte()
        return b
    }

    private val WALL_NOW = 1_783_786_000L    // 2026-07-11 ~16:06, just after the captured newest
    private val REAL_NEWEST = 1_783_785_625L // 2026-07-11 16:00:25 (frame a)

    @Test
    fun `reads the real WHOOP4 newest at byte offset 8 (old scan-from-7 missed it, returned null)`() {
        // Three real captured frames → their true newest (offset-8 u32), all 2026-07-11 ~16:00, a few
        // seconds apart. Each is well behind WALL_NOW, so none is treated as future.
        val expected = mapOf(
            "aa100057305d22009968526a083900001d2e2263" to 1_783_785_625L, // 16:00:25
            "aa10005730612200a268526ab0290000e87d155d" to 1_783_785_634L, // 16:00:34
            "aa100057307c2200e768526a78760000c997138d" to 1_783_785_703L, // 16:01:43
        )
        for ((h, ts) in expected) {
            assertEquals(
                "newest for $h should be its offset-8 value, not null",
                ts,
                WhoopBleClient.dataRangeNewestUnix(hex(h), WALL_NOW),
            )
        }
    }

    @Test
    fun `a lone future-dated straddle never becomes the frontier`() {
        // Real "today" word plus a fabricated far-future word: the true frontier is today, not the future.
        val future = WALL_NOW + 400L * 86_400L
        val frame = frameWithU32(16, 4, REAL_NEWEST)
        for (k in 0..3) frame[10 + k] = ((future shr (8 * k)) and 0xFF).toByte()
        assertEquals(REAL_NEWEST, WhoopBleClient.dataRangeNewestUnix(frame, WALL_NOW))
    }

    @Test
    fun `all-future frame (genuinely wrong RTC) still returns future so the guard fires`() {
        // The strap's ONLY plausible-unix word is future → return it so isFutureDatedNewest detects the
        // real bad-clock case and the periodic/auto-continue guards correctly refuse the range (#928).
        val future = WALL_NOW + 400L * 86_400L
        assertEquals(future, WhoopBleClient.dataRangeNewestUnix(frameWithU32(12, 4, future), WALL_NOW))
    }

    @Test
    fun `a value just inside the 48h skew is treated as present, not future`() {
        val within = WALL_NOW + 40L * 3600L   // 40h ahead, under the 48h AUTO_CONTINUE_FUTURE_SKEW
        assertEquals(within, WhoopBleClient.dataRangeNewestUnix(frameWithU32(12, 4, within), WALL_NOW))
    }
}
