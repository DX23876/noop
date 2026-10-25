package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #324 — the pure strap-log formatters for a bad-clock strap. Deterministic (now is injected). MUST produce
 * byte-identical strings to the Swift `BadClockDiagnostics` (BadClockDiagnosticsTests.swift) — same dates,
 * same wording — so a shared strap log reads identically on both platforms.
 */
class BadClockDiagnosticsTest {

    @Test fun isoDayIsUtc() {
        // 1_735_084_800 == 2024-12-25 00:00 UTC (the #547 tests' documented badYule anchor).
        assertEquals("2024-12-25", BadClockDiagnostics.isoDay(1_735_084_800L))
    }

    @Test fun hoursOffsetWording() {
        val now = 1_783_843_824L
        assertEquals("26445h ahead", BadClockDiagnostics.hoursOffset(now + 26_445L * 3600L, now))
        assertEquals("512h behind", BadClockDiagnostics.hoursOffset(now - 512L * 3600L, now))
        assertEquals("~now", BadClockDiagnostics.hoursOffset(now + 60L, now))   // within an hour
    }

    @Test fun droppedSpanClause() {
        val now = 1_783_843_824L
        // Nothing dropped → empty clause so the base sentence reads normally.
        assertEquals("", BadClockDiagnostics.droppedSpanClause(null, null, now))
        // A range → "oldest -> newest, offset(newest)". Built from the same pinned primitives (isoDay/
        // hoursOffset covered above) so this pins the ASSEMBLY, not hand-computed dates.
        val o = 1_845_000_000L
        val n = 1_876_000_000L
        val expected = " (dated ${BadClockDiagnostics.isoDay(o)} -> ${BadClockDiagnostics.isoDay(n)}, " +
            "${BadClockDiagnostics.hoursOffset(n, now)})"
        assertEquals(expected, BadClockDiagnostics.droppedSpanClause(o, n, now))
        assertTrue(expected.contains("->"))
        // oldest == newest → single date, no arrow.
        val single = BadClockDiagnostics.droppedSpanClause(n, n, now)
        assertFalse(single.contains("->"))
        assertEquals(" (dated ${BadClockDiagnostics.isoDay(n)}, ${BadClockDiagnostics.hoursOffset(n, now)})", single)
    }
}
