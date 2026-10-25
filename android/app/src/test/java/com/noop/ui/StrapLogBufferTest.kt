package com.noop.ui

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the two BOUNDS of the scheduled-export rolling buffer (#510) plus the timestamped filename
 * formatter. The whole point of the feature is that a debug log can sit accruing for ~24h WITHOUT growing
 * without limit, and that day-after-day auto-exports never collide — so a regression in either bound or
 * the stamp format is exactly what these guard. Pure JVM (no Android), so it runs in the unit-test JVM.
 */
class StrapLogBufferTest {

    @After fun tearDown() = StrapLogBuffer.clear()

    // --- Line-count bound ---

    @Test
    fun cappedAtMaxLines() {
        StrapLogBuffer.clear()
        val now = 1_000_000_000_000L
        // Append well over the cap, all stamped "now" so the time window never evicts them — only the
        // line cap can. (Append one-per-call so each is its own entry.)
        for (i in 0 until StrapLogBuffer.MAX_LINES + 500) {
            StrapLogBuffer.append("line $i", nowMs = now)
        }
        assertEquals(StrapLogBuffer.MAX_LINES, StrapLogBuffer.size(now))
        // Eviction is oldest-first, so the newest line survives and the oldest 500 are gone.
        val snap = StrapLogBuffer.snapshot(now)
        assertTrue(snap.endsWith("line ${StrapLogBuffer.MAX_LINES + 499}"))
        assertFalse(snap.contains("line 0\n") || snap == "line 0")
    }

    // --- Time-window bound (~24h rolling) ---

    @Test
    fun dropsLinesOlderThanRetentionWindow() {
        StrapLogBuffer.clear()
        val day0 = 1_000_000_000_000L
        StrapLogBuffer.append("old line", nowMs = day0)
        // 25h later — strictly past the 24h window, so the old line must be evicted on the next touch.
        val later = day0 + StrapLogBuffer.RETENTION_MS + 60L * 60L * 1000L
        StrapLogBuffer.append("fresh line", nowMs = later)
        val snap = StrapLogBuffer.snapshot(later)
        assertEquals("fresh line", snap)
        assertEquals(1, StrapLogBuffer.size(later))
    }

    @Test
    fun keepsLinesInsideRetentionWindow() {
        StrapLogBuffer.clear()
        val t0 = 1_000_000_000_000L
        StrapLogBuffer.append("a", nowMs = t0)
        // 23h later — still inside the 24h window, so both lines survive.
        val t1 = t0 + 23L * 60L * 60L * 1000L
        StrapLogBuffer.append("b", nowMs = t1)
        assertEquals("a\nb", StrapLogBuffer.snapshot(t1))
        assertEquals(2, StrapLogBuffer.size(t1))
    }

    // --- Append semantics ---

    @Test
    fun appendSplitsMultilineBlobs() {
        StrapLogBuffer.clear()
        val now = 1_000_000_000_000L
        StrapLogBuffer.append("one\ntwo\nthree", nowMs = now)
        assertEquals(3, StrapLogBuffer.size(now))
        assertEquals("one\ntwo\nthree", StrapLogBuffer.snapshot(now))
    }

    @Test
    fun replaceWithDiscardsPriorContents() {
        StrapLogBuffer.clear()
        val now = 1_000_000_000_000L
        StrapLogBuffer.append("stale", nowMs = now)
        StrapLogBuffer.replaceWith("only this\nand this", nowMs = now)
        assertEquals("only this\nand this", StrapLogBuffer.snapshot(now))
    }

    @Test
    fun blankAppendIsIgnored() {
        StrapLogBuffer.clear()
        val now = 1_000_000_000_000L
        StrapLogBuffer.append("   ", nowMs = now)
        StrapLogBuffer.append("", nowMs = now)
        assertEquals(0, StrapLogBuffer.size(now))
    }

    // --- Timestamped filename formatter (#510) ---

    @Test
    fun exportStampIsFullSecondPrecisionUtcStable() {
        // A fixed epoch → a deterministic YYYYMMDD-HHMMSS stamp. Using a UTC-anchored expectation would be
        // timezone-dependent, so assert SHAPE precisely instead: 8 digits, dash, 6 digits.
        val stamp = LogExport.exportStamp(1_700_000_000_000L)
        assertTrue("stamp '$stamp' must be YYYYMMDD-HHMMSS", Regex("""\d{8}-\d{6}""").matches(stamp))
    }

    @Test
    fun scheduledFilenamesUseStampAndCorrectExtensions() {
        val now = 1_700_000_000_000L
        val stamp = LogExport.exportStamp(now)
        assertEquals("noop-straplog-$stamp.txt", LogExport.strapLogFilename(now))
        assertEquals("noop-straplog-$stamp.bin", LogExport.rawCaptureFilename(now))
    }

    @Test
    fun secondPrecisionDistinguishesSameMinuteExports() {
        // Two exports one second apart in the same minute must NOT collide — the whole reason the scheduled
        // stamp is second-precision rather than the interactive minute stamp.
        val a = LogExport.strapLogFilename(1_700_000_000_000L)
        val b = LogExport.strapLogFilename(1_700_000_001_000L)
        assertFalse("same-minute exports collided: $a", a == b)
    }
}
