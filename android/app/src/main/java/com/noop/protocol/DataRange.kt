package com.noop.protocol

/**
 * GET_DATA_RANGE frame parsing. Byte-identical twin of Swift `WhoopProtocol.DataRange` — the newest-record
 * read gates automatic sync (`isFutureDatedNewest` -> BackfillPolicy), so its value must match across
 * platforms. Extracted from WhoopBleClient (#286 follow-up) so both a Kotlin JVM test and a WhoopProtocol
 * `swift test` pin the parity.
 */
object DataRange {
    /**
     * The newest plausible unix time banked by the strap, from a GET_DATA_RANGE frame. Scans EVERY byte
     * offset (the newest-record u32 isn't on a fixed grid — it sits at byte offset 8 on WHOOP 4, off the
     * old aligned-from-7 scan), keeps the newest word in a plausible unix window (2023-11..2030-03),
     * preferring the newest that is NOT implausibly future (> wallNowUnix + futureSkewSeconds) so a garbage
     * future word can't latch and stall auto-sync (#451/#928/#1012). Falls back to the newest-any word so a
     * genuinely future-dated RTC is still surfaced downstream. null only for a too-short frame or no
     * plausible word. Mirrors Swift `DataRange.newestUnix`.
     */
    fun newestUnix(frame: ByteArray, wallNowUnix: Long, futureSkewSeconds: Long): Long? {
        if (frame.size < 4) return null
        val futureCutoff = wallNowUnix + futureSkewSeconds
        var newestNotFuture: Long? = null
        var newestAny: Long? = null
        var i = 0
        while (i + 4 <= frame.size) {
            val w = (frame[i].toLong() and 0xFFL) or
                ((frame[i + 1].toLong() and 0xFFL) shl 8) or
                ((frame[i + 2].toLong() and 0xFFL) shl 16) or
                ((frame[i + 3].toLong() and 0xFFL) shl 24)
            if (w in 1_700_000_000L..1_900_000_000L) {
                newestAny = maxOf(newestAny ?: 0L, w)
                if (w <= futureCutoff) newestNotFuture = maxOf(newestNotFuture ?: 0L, w)
            }
            i += 1
        }
        return newestNotFuture ?: newestAny
    }
}
