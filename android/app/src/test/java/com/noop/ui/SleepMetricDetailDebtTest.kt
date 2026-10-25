package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Test

class SleepMetricDetailDebtTest {
    private fun day(key: String, asleepMin: Double?) = DailyMetric(
        deviceId = "my-whoop",
        day = key,
        totalSleepMin = asleepMin,
        deepMin = 80.0,
        remMin = 90.0,
        lightMin = 190.0,
        efficiency = 0.9,
    )

    @Test
    fun detailDebtUsesTheSameCarryRecurrenceAsTheCard() {
        val days = listOf(day("2026-06-01", 360.0), day("2026-06-02", 480.0))

        val card = buildSleepModel(days, session = null, todayKey = "2026-06-03")!!
        val detail = buildSleepMetricPoints(days, "sleep_debt")

        assertEquals(36.3, card.sleepDebt.latest!!, 1e-9)
        assertEquals(card.sleepDebt.latest!!, detail.last().second, 1e-9)
    }

    @Test
    fun detailDebtPreservesImportedValueAndCreditsNaps() {
        val days = listOf(day("2026-06-01", 360.0), day("2026-06-02", 400.0))
        val imported = ImportedSleepSeries(debtMin = mapOf("2026-06-02" to 61.25))

        val importedPoints = buildSleepMetricPoints(days, "sleep_debt", imported = imported)
        assertEquals(61.25, importedPoints.last().second, 1e-9)

        val card = buildSleepModel(
            days,
            session = null,
            napSleepMinByDay = mapOf("2026-06-02" to 80.0),
            todayKey = "2026-06-03",
        )!!
        val napPoints = buildSleepMetricPoints(
            days,
            "sleep_debt",
            napSleepMinByDay = mapOf("2026-06-02" to 80.0),
        )
        assertEquals(card.sleepDebt.latest!!, napPoints.last().second, 1e-9)
    }
}
