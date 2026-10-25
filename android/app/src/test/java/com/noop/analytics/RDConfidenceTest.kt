package com.noop.analytics

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RDConfidenceTests.swift (Wave 0 · RD-confidence,
 * PR #456).
 *
 * The readiness read now carries a [ScoreConfidence] from its baseline density, so the card can say
 * calibrating / building / solid instead of a confident number off a 7-night baseline (Charge already
 * does this; readiness didn't). Same fixtures and assertions as the Swift test.
 */
class RDConfidenceTest {

    @Test
    fun readinessConfidenceTiers() {
        assertEquals(
            ScoreConfidence.CALIBRATING,
            ScoreConfidence.readiness(hasRead = false, baselineNights = 40, fullWindow = 30),
        )
        assertEquals(
            ScoreConfidence.BUILDING,
            ScoreConfidence.readiness(hasRead = true, baselineNights = 12, fullWindow = 30),
        )
        assertEquals(
            ScoreConfidence.SOLID,
            ScoreConfidence.readiness(hasRead = true, baselineNights = 30, fullWindow = 30),
        )
    }

    private fun d(i: Int, hrv: Double?, rhr: Int?): DailyMetric = DailyMetric(
        deviceId = "test",
        day = "2024-03-%02d".format(i),
        restingHr = rhr,
        avgHrv = hrv,
        strain = 10.0,
    )

    @Test
    fun emptyHistoryReadsCalibrating() {
        assertEquals(ScoreConfidence.CALIBRATING, ReadinessEngine.evaluate(emptyList()).confidence)
    }

    @Test
    fun thinBaselineReadsBuilding() {
        // 10 baseline nights + today: a read exists but baseline < the 30-night window → building.
        val days = mutableListOf<DailyMetric>()
        for (i in 1..10) days.add(d(i, hrv = if (i % 2 == 0) 62.0 else 58.0, rhr = 52))
        days.add(d(11, hrv = 60.0, rhr = 52))
        val r = ReadinessEngine.evaluate(days)
        assertNotEquals(ReadinessEngine.Level.INSUFFICIENT, r.level)
        assertEquals(ScoreConfidence.BUILDING, r.confidence)
    }

    @Test
    fun fullBaselineReadsSolid() {
        val days = mutableListOf<DailyMetric>()
        for (i in 1..30) days.add(d(i, hrv = if (i % 2 == 0) 62.0 else 58.0, rhr = 52))
        days.add(d(31, hrv = 60.0, rhr = 52))
        assertEquals(ScoreConfidence.SOLID, ReadinessEngine.evaluate(days).confidence)
    }
}
