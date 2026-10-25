package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.StepSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #277 — daily metrics must bucket by the device's LOCAL calendar day, consistently with the
 * dashboard's local "today" lookup. A west-of-UTC user's evening data crosses midnight UTC into
 * the next UTC bucket; the local "today" read can't find it, so the dashboard freezes.
 *
 * Mirrors the Swift StrandAnalytics AnalyticsEngineTests + WhoopStore MetricsCacheTests additions
 * byte-for-byte in logic/constants. Pure unit tests — no Room/DB.
 */
class LocalDayBucketingTest {

    // --- AnalyticsEngine.dayString(ts, offsetSec) ---------------------------

    @Test
    fun dayString_localEveningWestOfUTC() {
        // A Toronto user (UTC-4) at 22:00 local on 2021-06-15. Local 22:00 EDT == 02:00 UTC the NEXT
        // day (2021-06-16). The UTC bucket would be "2021-06-16"; the LOCAL day is "2021-06-15".
        // 2021-06-16 02:00:00 UTC == 1623808800.
        val tsUtc = 1_623_808_800L
        val offset = -4 * 3600L // UTC-4
        assertEquals("2021-06-16", AnalyticsEngine.dayString(tsUtc))                   // old UTC behaviour
        assertEquals("2021-06-15", AnalyticsEngine.dayString(tsUtc, offset))           // local day
    }

    @Test
    fun dayString_offsetZeroMatchesUTC() {
        // Offset 0 must be byte-identical to the legacy UTC behaviour for every caller/test.
        val ts = 1_609_459_200L
        assertEquals(AnalyticsEngine.dayString(ts), AnalyticsEngine.dayString(ts, 0L))
        assertEquals(AnalyticsEngine.dayString(ts + 45_000L), AnalyticsEngine.dayString(ts + 45_000L, 0L))
    }

    @Test
    fun dayString_samplesSpanningOneLocalDayMapToOneKey() {
        // Every wall-clock second across a UTC-4 user's local 2021-06-15 (00:00 -> 23:59:59 local)
        // must map to the single key "2021-06-15", even though the late-evening hours cross midnight
        // UTC into 2021-06-16. Local 00:00 EDT 2021-06-15 == 04:00 UTC == 1623729600.
        val offset = -4 * 3600L
        val localMidnightUtc = 1_623_729_600L // 2021-06-15 00:00:00 local (04:00 UTC)
        val probes = listOf(0L, 12 * 3600L, 20 * 3600L, 24 * 3600L - 1L)
        for (p in probes) {
            assertEquals(
                "local-day probe at +${p}s mis-bucketed",
                "2021-06-15",
                AnalyticsEngine.dayString(localMidnightUtc + p, offset),
            )
        }
        // One second earlier / one second past the local day fall on the neighbours.
        assertEquals("2021-06-14", AnalyticsEngine.dayString(localMidnightUtc - 1L, offset))
        assertEquals("2021-06-16", AnalyticsEngine.dayString(localMidnightUtc + 24 * 3600L, offset))
    }

    @Test
    fun dayString_eastOfUTC() {
        // A Tokyo user (UTC+9) just after local midnight on 2021-06-16 (15:30 UTC on 2021-06-15) is
        // on local day 2021-06-16 while the UTC bucket is still 2021-06-15.
        // 2021-06-15 15:30:00 UTC == 1623771000.
        val tsUtc = 1_623_771_000L
        val offset = 9 * 3600L
        assertEquals("2021-06-15", AnalyticsEngine.dayString(tsUtc))
        assertEquals("2021-06-16", AnalyticsEngine.dayString(tsUtc, offset))
    }

    // --- IntelligenceEngine.midnightLocal(ts, offsetSec) --------------------

    @Test
    fun midnightLocal_floorsToLocalMidnightWestOfUTC() {
        // UTC-4: local 21:00 on 2021-06-15 == 01:00 UTC 2021-06-16 == 1623805200. Local midnight is
        // 2021-06-15 00:00 local == 04:00 UTC == 1623729600.
        val offset = -4 * 3600L
        val tsUtc = 1_623_805_200L
        assertEquals(1_623_729_600L, IntelligenceEngine.midnightLocal(tsUtc, offset))
        // The floored value + offset, in UTC, is itself a midnight (key boundary holds).
        assertEquals("2021-06-15", AnalyticsEngine.dayString(IntelligenceEngine.midnightLocal(tsUtc, offset), offset))
    }

    @Test
    fun midnightLocal_offsetZeroEqualsMidnightUtc() {
        // floorMod-based local floor with offset 0 must equal the legacy UTC midnight floor for any sign.
        val samples = listOf(1_609_459_200L, 1_609_459_200L + 45_000L, 0L, 86_399L, -1L, -86_401L)
        for (ts in samples) {
            assertEquals(
                "midnightLocal(offset=0) must equal midnightUtc for ts=$ts",
                IntelligenceEngine.midnightUtc(ts),
                IntelligenceEngine.midnightLocal(ts, 0L),
            )
        }
    }

    @Test
    fun midnightLocal_negativeOffsetSignCorrect() {
        // The floored local midnight must be <= ts and exactly a local-day boundary (ts+offset
        // divisible by 86400). Guards floorMod sign for negative offsets/timestamps.
        val offset = -5 * 3600L // UTC-5
        for (ts in listOf(1_623_805_200L, 1_600_000_000L, 100L)) {
            val mid = IntelligenceEngine.midnightLocal(ts, offset)
            assertEquals("must land on a local-day boundary", 0L, Math.floorMod(mid + offset, 86_400L))
            assert(mid <= ts) { "midnight floor must not exceed ts" }
            assert(ts - mid < 86_400L) { "floor must be within the same local day" }
        }
    }

    // --- analyzeDay attributes samples by LOCAL day -------------------------

    @Test
    fun analyzeDay_stepsAttributedByLocalDay() {
        // A UTC-4 user's steps taken at local 21:00 on 2021-06-15 cross UTC midnight into 2021-06-16.
        // With the matching local-day key + tzOffset, analyzeDay must attribute them to the LOCAL day
        // 2021-06-15 (the bucket the dashboard reads), not the UTC day. Local 21:00 EDT 2021-06-15 ==
        // 01:00 UTC 2021-06-16 == 1623805200.
        val offset = -4 * 3600L
        val day = "2021-06-15"
        val lateEveningUtc = 1_623_805_200L
        val steps = listOf(
            StepSample(deviceId = "my-whoop", ts = lateEveningUtc, counter = 100),
            StepSample(deviceId = "my-whoop", ts = lateEveningUtc + 1800L, counter = 360), // +260
        )
        val withOffset = AnalyticsEngine.analyzeDay(
            day = day, steps = steps, profile = UserProfile(), tzOffsetSeconds = offset,
        ).daily.steps
        assertEquals(260, withOffset)
        // The OLD UTC bucketing (offset 0, UTC day key) would have dropped these → nil, proving the
        // offset is what saves them.
        val utc = AnalyticsEngine.analyzeDay(
            day = day, steps = steps, profile = UserProfile(), tzOffsetSeconds = 0L,
        ).daily.steps
        assertNull(utc)
    }

    // --- windowed computed-daily delete predicate (migration, test d) -------
    //
    // Mirrors the SQL the new WhoopDao.deleteComputedDailyInRange runs:
    //   DELETE FROM dailyMetric WHERE deviceId = :deviceId AND day >= :from AND day <= :to
    // (yyyy-MM-dd sorts chronologically, so a string BETWEEN is a date BETWEEN). A pure-logic mirror
    // because the project's unit tests don't spin up Room; the DAO @Query is the production path.

    private data class Row(val deviceId: String, val day: String)

    private fun applyDelete(rows: List<Row>, deviceId: String, from: String, to: String): List<Row> =
        rows.filterNot { it.deviceId == deviceId && it.day >= from && it.day <= to }

    @Test
    fun windowedDelete_keepsImportedAndOutOfRange() {
        val computed = "my-whoop-noop"
        val imported = "my-whoop"
        val rows = listOf(
            Row(computed, "2026-05-09"), // out of range (before)
            Row(computed, "2026-05-10"), // in range
            Row(computed, "2026-05-11"), // in range
            Row(computed, "2026-05-12"), // in range
            Row(computed, "2026-05-13"), // out of range (after)
            Row(imported, "2026-05-11"), // imported, in range — MUST survive
        )
        val after = applyDelete(rows, computed, "2026-05-10", "2026-05-12")
        // The 3 in-range computed rows are removed; out-of-range computed + the imported row survive.
        assertEquals(
            listOf(
                Row(computed, "2026-05-09"),
                Row(computed, "2026-05-13"),
                Row(imported, "2026-05-11"),
            ),
            after,
        )
    }

    @Test
    fun windowedDelete_doesNotWipeAllHistory() {
        // A BLE-only user with no import: only the recompute window is cleared; older computed days
        // (their cosmetic off-by-one UTC keys) are kept — there is no import fallback.
        val computed = "my-whoop-noop"
        val rows = (1..20).map { Row(computed, "2026-05-%02d".format(it)) }
        val after = applyDelete(rows, computed, "2026-05-10", "2026-05-20")
        assertEquals(9, after.size) // days 01..09 survive
        assertEquals("2026-05-09", after.last().day)
    }

    @Suppress("UNUSED_VARIABLE")
    private fun unusedDailyMetricShape() {
        // Compile-time anchor that the migration operates on DailyMetric rows.
        val d = DailyMetric(deviceId = "my-whoop-noop", day = "2026-05-11")
        assertEquals("my-whoop-noop", d.deviceId)
    }
}
