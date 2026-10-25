package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #117 — crediting an imported exercise session with the active calories burned inside its window.
 * Time-weighted overlap so a per-activity record counts in full while a day-spanning total record
 * only contributes the session's slice.
 */
class HealthConnectActiveKcalTest {

    // Single-source by default: every pre-#835 assertion below is about one writing app, where
    // "sum within a source, max across sources" is identical to the old plain sum.
    private fun rec(start: Long, end: Long, kcal: Double, source: String = "app.a") =
        HealthConnectImporter.KcalRecord(start, end, kcal, source)

    @Test fun noRecordsGivesNull() {
        assertNull(HealthConnectImporter.sumKcalInWindow(emptyList(), 100, 200))
    }

    @Test fun aRecordFullyInsideCountsInFull() {
        val recs = listOf(rec(120, 180, 300.0))
        assertEquals(300.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aRecordExactlyMatchingTheSessionCountsInFull() {
        val recs = listOf(rec(100, 200, 250.0))
        assertEquals(250.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aNonOverlappingRecordIsIgnored() {
        val recs = listOf(rec(300, 400, 500.0))
        assertNull(HealthConnectImporter.sumKcalInWindow(recs, 100, 200))
    }

    @Test fun multiplePerMinuteRecordsInsideAreSummed() {
        val recs = listOf(rec(100, 160, 60.0), rec(160, 200, 40.0))
        assertEquals(100.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun aDaySpanningRecordOnlyContributesTheSessionsFraction() {
        // 1440-min day record of 1440 kcal (1 kcal/min); a 60-min session should credit ~60 kcal.
        val dayStart = 0L
        val dayEnd = 86_400L
        val recs = listOf(rec(dayStart, dayEnd, 1440.0))
        val sessionKcal = HealthConnectImporter.sumKcalInWindow(recs, 10_000, 13_600)!! // 3600 s = 60 min
        assertEquals(1440.0 * (3600.0 / 86_400.0), sessionKcal, 0.001) // = 60.0
    }

    @Test fun partialOverlapIsProRated() {
        // Record [150,250] of 100 kcal; session [100,200] overlaps [150,200] = 50 of the 100 s span.
        val recs = listOf(rec(150, 250, 100.0))
        assertEquals(50.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    // --- #835: cross-source double-count ---

    /** Two apps logging the same ride used to be ADDED. Day totals de-overlap per source (#589); this
     *  did not, so a phone + watch pair roughly doubled a session. Max across sources, sum within one. */
    @Test fun twoSourcesOverTheSameSessionAreNotAdded() {
        val recs = listOf(rec(100, 200, 300.0, "phone"), rec(100, 200, 290.0, "watch"))
        assertEquals(300.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    @Test fun recordsWithinOneSourceStillSum_acrossSourcesStillMax() {
        val recs = listOf(
            rec(100, 150, 50.0, "phone"), rec(150, 200, 60.0, "phone"),  // one source → 110
            rec(100, 200, 90.0, "watch"),                                 // other source → 90
        )
        assertEquals(110.0, HealthConnectImporter.sumKcalInWindow(recs, 100, 200)!!, 0.001)
    }

    // --- #835: sessions whose source writes only TotalCaloriesBurned ---

    private fun kcal(active: List<HealthConnectImporter.KcalRecord>,
                     total: List<HealthConnectImporter.KcalRecord>,
                     basal: Double?, start: Long, end: Long) =
        HealthConnectImporter.workoutKcal(active, total, basal, start, end)

    /** The reported shape: the ride's app wrote Total only, so the workout was credited with nothing but
     *  unrelated background Active. Total minus the window's basal share must win. */
    @Test fun totalOnlySourceBeatsStrayBackgroundActive() {
        val h = 3600L
        val strayActive = listOf(rec(0, 86_400, 240.0, "phone"))     // a whole day → 10 kcal for one hour
        val sessionTotal = listOf(rec(10_000, 10_000 + h, 700.0, "bike"))
        // basal 1680/day → 70 for the hour ⇒ 700 − 70 = 630, vs 10 from the stray Active.
        val got = kcal(strayActive, sessionTotal, 1680.0, 10_000, 10_000 + h)!!
        assertEquals(630.0, got, 0.001)
    }

    /** A coarse daily Active record prorates to a uniform slice, which badly understates a hard hour.
     *  A session-scoped Total record resolves the same hour properly and should win. */
    @Test fun coarseDailyActiveLosesToSessionScopedTotal() {
        val h = 3600L
        val coarseActive = listOf(rec(0, 86_400, 1440.0, "phone"))   // → 60 kcal for the hour
        val sessionTotal = listOf(rec(10_000, 10_000 + h, 500.0, "bike"))
        val got = kcal(coarseActive, sessionTotal, 1680.0, 10_000, 10_000 + h)!!
        assertEquals(430.0, got, 0.001)                               // 500 − 70 basal
    }

    /** A good Active credit must NOT be replaced — the estimate is a max, never an override. */
    @Test fun aRealActiveCreditIsKeptWhenItIsTheLarger() {
        val h = 3600L
        val goodActive = listOf(rec(10_000, 10_000 + h, 650.0, "bike"))
        val sessionTotal = listOf(rec(10_000, 10_000 + h, 700.0, "bike"))
        val got = kcal(goodActive, sessionTotal, 1680.0, 10_000, 10_000 + h)!!
        assertEquals(650.0, got, 0.001)                               // 650 > 700 − 70 = 630
    }

    /** Basal must not be able to drive the estimate negative or to zero — nulls out instead. */
    @Test fun basalLargerThanTotalYieldsNoTotalEstimate() {
        val h = 3600L
        val total = listOf(rec(10_000, 10_000 + h, 40.0, "bike"))
        assertNull(kcal(emptyList(), total, 8640.0, 10_000, 10_000 + h))   // basal share 360 > 40
    }

    /** No basal known (a day with no Total aggregate) falls back to raw Total rather than nothing. */
    @Test fun missingBasalFallsBackToRawTotal() {
        val h = 3600L
        val total = listOf(rec(10_000, 10_000 + h, 500.0, "bike"))
        assertEquals(500.0, kcal(emptyList(), total, null, 10_000, 10_000 + h)!!, 0.001)
    }

    /** Neither stream covering the session is still null — no fabricated number. */
    @Test fun noCoverageAtAllIsNull() {
        assertNull(kcal(emptyList(), emptyList(), 1680.0, 10_000, 13_600))
    }
}
