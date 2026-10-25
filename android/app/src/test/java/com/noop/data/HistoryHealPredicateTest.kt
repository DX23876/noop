package com.noop.data

import com.noop.protocol.FUTURE_MARGIN
import com.noop.protocol.MIN_PLAUSIBLE_UNIX
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #547 one-time heal predicates (pure, no DB). A bad strap clock/flash (pikapik) wrote raw + computed
 * rows with implausible timestamps BEFORE the ingest gate existed; the heal purges them on upgrade. These
 * pin the SAME boundary the SQL deletes apply, so the heal can never (a) keep a far-past / future-dated
 * polluted row or (b) wrongly delete a real recent one. Bounds mirror the ingest gate exactly.
 */
class HistoryHealPredicateTest {

    private val now = 1_780_916_150L          // ~2026-06, the worn-frame reference time
    private val maxTs = now + FUTURE_MARGIN

    @Test fun ts_farPastIsImplausible() {
        assertTrue(HistoryHeal.isImplausibleTs(1_550_000_000L, now))   // 2019, < 1.7B floor
        assertTrue(HistoryHeal.isImplausibleTs(0L, now))               // epoch / reset RTC
        assertTrue(HistoryHeal.isImplausibleTs(MIN_PLAUSIBLE_UNIX - 1, now))
    }

    @Test fun ts_futureDatedIsImplausible() {
        assertTrue(HistoryHeal.isImplausibleTs(maxTs + 1, now))        // 1s past the +1-day margin
        assertTrue(HistoryHeal.isImplausibleTs(now + 30 * 86_400, now)) // a month into the future
    }

    @Test fun ts_recentIsPlausible_andBoundariesAreInclusive() {
        assertFalse(HistoryHeal.isImplausibleTs(now, now))            // exactly now
        assertFalse(HistoryHeal.isImplausibleTs(MIN_PLAUSIBLE_UNIX, now)) // floor inclusive
        assertFalse(HistoryHeal.isImplausibleTs(maxTs, now))         // +1-day margin inclusive
        assertFalse(HistoryHeal.isImplausibleTs(now - 14 * 86_400, now)) // a normal two-week-old night
    }

    @Test fun day_futureKeyIsImplausible() {
        // ISO date strings sort chronologically, so a plain compare is correct.
        assertTrue(HistoryHeal.isImplausibleDay("2026-07-12", today = "2026-06-19", minDay = "2023-11-14"))
        assertTrue(HistoryHeal.isImplausibleDay("2027-01-01", today = "2026-06-19", minDay = "2023-11-14"))
    }

    @Test fun day_tooOldKeyIsImplausible() {
        assertTrue(HistoryHeal.isImplausibleDay("2020-01-01", today = "2026-06-19", minDay = "2023-11-14"))
    }

    @Test fun day_realRecentKeyIsPlausible_andTodayIsInclusive() {
        assertFalse(HistoryHeal.isImplausibleDay("2026-06-18", today = "2026-06-19", minDay = "2023-11-14"))
        assertFalse(HistoryHeal.isImplausibleDay("2026-06-19", today = "2026-06-19", minDay = "2023-11-14")) // == today
        assertFalse(HistoryHeal.isImplausibleDay("2023-11-14", today = "2026-06-19", minDay = "2023-11-14")) // == floor
    }
}
