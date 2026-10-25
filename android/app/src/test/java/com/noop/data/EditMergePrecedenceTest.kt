package com.noop.data

import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.RestScorer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.TimeZone

/**
 * Pins the H5 edit-merge precedence (#509) + the v18 per-epoch JSON codecs, the Android twins of the
 * Swift EditMergePrecedenceTests / SleepMotionStateTests. All pure (no Room) — exercise the companion
 * [WhoopRepository.mergeDaily] / [WhoopRepository.userEditedDays] and the JSON helpers directly.
 */
class EditMergePrecedenceTest {

    private fun full(
        day: String,
        totalSleepMin: Double,
        deepMin: Double,
        remMin: Double,
        lightMin: Double,
        efficiency: Double,
        recovery: Double,
        strain: Double,
        source: String,
    ) = DailyMetric(
        deviceId = source,
        day = day,
        totalSleepMin = totalSleepMin,
        efficiency = efficiency,
        deepMin = deepMin,
        remMin = remMin,
        lightMin = lightMin,
        recovery = recovery,
        strain = strain,
    )

    @Test
    fun editedDay_computedSleepWins_importNonSleepWins() {
        val imported = full("2026-06-12", 480.0, 90.0, 110.0, 280.0, 0.92, 80.0, 9.0, "my-whoop")
        val computed = full("2026-06-12", 300.0, 50.0, 70.0, 180.0, 0.85, 55.0, 14.0, "my-whoop-noop")

        val merged = WhoopRepository.mergeDaily(
            imported = listOf(imported),
            computed = listOf(computed),
            userEditedDays = setOf("2026-06-12"),
        )

        assertEquals(1, merged.size)
        // Sleep: computed (the edit) wins.
        assertEquals(300.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(50.0, merged[0].deepMin!!, 0.0)
        assertEquals(70.0, merged[0].remMin!!, 0.0)
        assertEquals(180.0, merged[0].lightMin!!, 0.0)
        assertEquals(0.85, merged[0].efficiency!!, 0.0)
        // Non-sleep: import still wins.
        assertEquals(80.0, merged[0].recovery!!, 0.0)
        assertEquals(9.0, merged[0].strain!!, 0.0)
    }

    @Test
    fun nonEditedDay_importWinsSleep() {
        val imported = full("2026-06-12", 480.0, 90.0, 110.0, 280.0, 0.92, 80.0, 9.0, "my-whoop")
        val computed = full("2026-06-12", 300.0, 50.0, 70.0, 180.0, 0.85, 55.0, 14.0, "my-whoop-noop")

        val merged = WhoopRepository.mergeDaily(imported = listOf(imported), computed = listOf(computed))

        assertEquals(480.0, merged[0].totalSleepMin!!, 0.0)
        assertEquals(90.0, merged[0].deepMin!!, 0.0)
        assertEquals(0.92, merged[0].efficiency!!, 0.0)
    }

    @Test
    fun importedRowGapFillsComputedSdnnWithoutConflatingHrv() {
        val imported = DailyMetric("apple-health", "2026-06-12", avgHrv = 44.0)
        val computed = DailyMetric("my-whoop-noop", "2026-06-12", avgHrv = 55.0, avgSdnn = 88.0)
        val merged = WhoopRepository.mergeDaily(listOf(imported), listOf(computed)).single()
        assertEquals(44.0, merged.avgHrv!!, 0.0)
        assertEquals(88.0, merged.avgSdnn!!, 0.0)
    }

    @Test
    fun userEditedDays_keyedByLocalWakeDay() {
        val endTs = 1_780_000_000L
        val edited = SleepSession(
            deviceId = "my-whoop-noop", startTs = endTs - 8 * 3600, endTs = endTs,
            efficiency = 0.85, restingHr = 52, avgHrv = 70.0, stagesJSON = "[]", userEdited = true,
        )
        val plain = edited.copy(startTs = endTs - 30 * 3600, endTs = endTs - 22 * 3600, userEdited = false)

        val days = WhoopRepository.userEditedDays(listOf(edited, plain))
        val offsetSec = (TimeZone.getDefault().getOffset(endTs * 1000) / 1000).toLong()
        assertEquals(setOf(AnalyticsEngine.dayString(endTs, offsetSec)), days)
    }

    // MARK: - v18 per-epoch JSON codecs (byte-equivalent with Swift JSONEncoder/JSONDecoder)

    @Test
    fun doubleArray_encodesSwiftCompactForm() {
        // Whole doubles drop the trailing .0 (Swift encodes 3.0 as `3`, 0.0 as `0`).
        assertEquals("[0,1.5,12.25,3]", WhoopRepository.encodeDoubleArray(listOf(0.0, 1.5, 12.25, 3.0)))
    }

    @Test
    fun doubleArray_roundTrips() {
        val xs = listOf(0.0, 1.5, 12.25, 3.0, 0.5)
        assertEquals(xs, WhoopRepository.decodeDoubleArray(WhoopRepository.encodeDoubleArray(xs)))
    }

    @Test
    fun intArray_roundTrips() {
        val xs = listOf(0, 1, 2, 3, 1, 0)
        assertEquals("[0,1,2,3,1,0]", WhoopRepository.encodeIntArray(xs))
        assertEquals(xs, WhoopRepository.decodeIntArray(WhoopRepository.encodeIntArray(xs)))
    }

    @Test
    fun decode_unparseable_returnsNull() {
        assertNull(WhoopRepository.decodeDoubleArray("not json"))
        assertNull(WhoopRepository.decodeIntArray("{\"x\":1}"))
    }

    // MARK: - sleep_performance daily-column derivation (#614)
    //
    // The resolver derives the Rest composite from a banked DailyMetric's sleep totals when no
    // metricSeries point covers the day (a Bluetooth-only / just-synced selected day). Without it the
    // selected day resolved to nothing and Today borrowed the latest historical Rest.

    @Test
    fun sleepPerformance_dailyColumn_derivesRestFromTotals() {
        val d = full("2026-06-12", 480.0, 90.0, 110.0, 280.0, 0.92, 80.0, 9.0, "my-whoop-noop")
        // Matches IntelligenceEngine's persisted sleep_performance projection (same single source of truth).
        val expected = RestScorer.restFromDaily(d)
        assertNotNull(expected)
        assertEquals(expected!!, WhoopRepository.dailyColumn("sleep_performance", d)!!, 0.0)
    }

    @Test
    fun sleepPerformance_dailyColumn_nullWhenNoSleep() {
        // No banked night (totalSleepMin null) → no Rest to derive; the resolver leaves the day empty
        // rather than fabricating a score.
        val d = DailyMetric(deviceId = "my-whoop-noop", day = "2026-06-12", recovery = 60.0)
        assertNull(WhoopRepository.dailyColumn("sleep_performance", d))
    }
}
