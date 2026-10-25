package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

/** #2522 daily-RHR parity twin of Swift PrimaryNightRestingHRDailyTests. */
class PrimaryNightRestingHRDailyTest {
    private val day = "2026-07-27"
    private val dayStart = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond()
    private val nightStart = dayStart - 4 * 3600
    private val napStart = dayStart + 13 * 3600
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")

    private fun sessions(primaryRhr: Int? = null): List<DetectedSleep> {
        val nightEnd = nightStart + 600 * 60
        val napEnd = napStart + 40 * 60
        return listOf(
            DetectedSleep(nightStart, nightEnd, 0.9,
                listOf(StageSegment(nightStart, nightEnd, "light")), restingHR = primaryRhr, avgHRV = null),
            DetectedSleep(napStart, napEnd, 0.9,
                listOf(StageSegment(napStart, napEnd, "light")), restingHR = null, avgHRV = null),
        )
    }

    private fun heartRate(includeNight: Boolean = true): List<HrSample> {
        val night = if (includeNight) (0 until 1200).map { i ->
            HrSample("t", nightStart + i * 30L, if (i < 10) 55 else 70)
        } else emptyList()
        val nap = (0 until 80).map { i -> HrSample("t", napStart + i * 30L, 45) }
        return night + nap
    }

    @Test fun mainNightFloorWinsOverItsMeanAndALowerNap() {
        val hr = heartRate()
        assertEquals(55, SleepStager.sessionRestingHR(nightStart, nightStart + 600 * 60, hr))
        assertTrue((AnalyticsEngine.primarySessionRestingHR(sessions(), hr) ?: 0.0) > 69.0)
        val result = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = emptyList(),
            profile = profile, providedSleep = sessions())
        assertEquals(55, result.daily.restingHr)
    }

    @Test fun providedPrimaryValueStillWins() {
        val result = AnalyticsEngine.analyzeDay(day = day, hr = heartRate(), rr = emptyList(),
            profile = profile, providedSleep = sessions(primaryRhr = 62))
        assertEquals(62, result.daily.restingHr)
    }

    @Test fun napDoesNotFillAnUnmeasuredPrimaryNight() {
        val result = AnalyticsEngine.analyzeDay(day = day, hr = heartRate(includeNight = false),
            rr = emptyList(), profile = profile, providedSleep = sessions())
        assertNull(result.daily.restingHr)
    }
}
