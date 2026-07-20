package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** #612: the "days since the newest night with a usable HRV" helper behind the "no new nights for N days"
 *  calibrating copy. Byte-identical twin of the Swift `Baselines.nightsSinceNewestValidNight`. */
class NightsSinceNewestValidNightTest {

    @Test
    fun `days since the newest night carrying a valid hrv`() {
        val days = listOf("2026-07-01", "2026-07-02", "2026-07-03")
        val hrv = listOf(60.0, null, 62.0) // newest valid night = 07-03
        assertEquals(14, Baselines.nightsSinceNewestValidNight(days, hrv, "2026-07-17"))
    }

    @Test
    fun `a null-hrv newer night does not count as the newest valid night`() {
        val days = listOf("2026-07-01", "2026-07-10")
        val hrv = listOf(55.0, null) // 07-10 has no hrv, so newest valid = 07-01
        assertEquals(16, Baselines.nightsSinceNewestValidNight(days, hrv, "2026-07-17"))
    }

    @Test
    fun `null when there is no valid night at all`() {
        assertNull(Baselines.nightsSinceNewestValidNight(listOf("2026-07-01"), listOf(null), "2026-07-17"))
    }

    @Test
    fun `null when today precedes the newest night (would be negative)`() {
        assertNull(Baselines.nightsSinceNewestValidNight(listOf("2026-07-20"), listOf(60.0), "2026-07-17"))
    }

    @Test
    fun `civil-day arithmetic crosses month and year boundaries`() {
        assertEquals(1, Baselines.nightsSinceNewestValidNight(listOf("2025-12-31"), listOf(50.0), "2026-01-01"))
        assertEquals(31, Baselines.nightsSinceNewestValidNight(listOf("2026-01-31"), listOf(50.0), "2026-03-03")) // Jan31->Mar3 (2026 not leap): 28-31=... 31 days
    }

    @Test
    fun `null on an unparseable day key`() {
        assertNull(Baselines.nightsSinceNewestValidNight(listOf("not-a-date"), listOf(50.0), "2026-07-17"))
    }
}
