package com.noop.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #126: live REALTIME_DATA carries the strap's OWN timestamp. On a strap with an invalid RTC that value
 * is a bogus uptime counter, not unix time — so an identity clock (device==wall==now) would stamp live HR
 * thousands of days off-today, and the Today 24h HR trend (which buckets hrSample over today's window)
 * reads empty even though live HR streamed and persisted all session.
 *
 * The live path now anchors the batch's NEWEST realtime timestamp to wall-clock `now` and lets earlier
 * samples fall relative to it, so live HR lands on today's timeline whatever the strap's clock says —
 * and is a no-op when the clock is already valid (newest frame ≈ now). Guards `extractStreams`' mapping,
 * which `WhoopBleClient.flushLive` relies on.
 */
class LiveRealtimeClockAnchorTest {
    private fun realtime(deviceTs: Int, hr: Int) = ParsedFrame(
        ok = true, crcOk = true, typeName = "REALTIME_DATA",
        parsed = mapOf("timestamp" to deviceTs, "heart_rate" to hr),
    )

    /** The fix: a bogus-RTC live batch, anchored newest-to-now, lands on today with spacing preserved. */
    @Test fun bogusRtcLiveHrLandsOnTodayWhenAnchoredToNow() {
        val now = 1_780_000_000
        // Strap RTC is a ~31M-second uptime counter (not unix time); three 1 Hz readings.
        val frames = listOf(realtime(31_000_000, 58), realtime(31_000_001, 60), realtime(31_000_002, 61))
        val newest = frames.mapNotNull { it.parsed.intOrNull("timestamp") }.max() // == 31_000_002
        val streams = extractStreams(frames, deviceClockRef = newest, wallClockRef = now)
        assertEquals(listOf(now - 2, now - 1, now), streams.hr.map { it.ts }) // anchored to today, spacing kept
        assertEquals(listOf(58, 60, 61), streams.hr.map { it.bpm })
    }

    /** The old identity clock would have stamped the same batch ~31M (1971) — far outside today's window. */
    @Test fun identityClockWouldHaveStampedOffToday() {
        val now = 1_780_000_000
        val frames = listOf(realtime(31_000_000, 58))
        val identity = extractStreams(frames, deviceClockRef = now, wallClockRef = now)
        assertEquals(31_000_000, identity.hr.first().ts) // the bug: nowhere near `now`
    }

    /** A strap whose clock already ≈ wall-clock is unaffected (anchoring is a no-op). */
    @Test fun validClockIsUnchanged() {
        val now = 1_780_000_000
        val frames = listOf(realtime(now - 2, 58), realtime(now - 1, 60), realtime(now, 61))
        val streams = extractStreams(frames, deviceClockRef = now, wallClockRef = now)
        assertEquals(listOf(now - 2, now - 1, now), streams.hr.map { it.ts })
    }
}
