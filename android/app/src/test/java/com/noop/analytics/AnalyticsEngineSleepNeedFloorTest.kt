package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Public [AnalyticsEngine.analyzeDay] contract for degenerate sleep-need inputs. The Swift twin uses
 * the same provided 30-second light-sleep session and asserts the same rounded Rest projection.
 */
class AnalyticsEngineSleepNeedFloorTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val day = "2025-06-10"
    private val sessionStart = 1_749_517_200L

    private fun rest(sleepNeedHours: Double): Double {
        val provided = DetectedSleep(
            start = sessionStart,
            end = sessionStart + 30L,
            efficiency = 1.0,
            stages = listOf(StageSegment(sessionStart, sessionStart + 30L, "light")),
            restingHR = null,
            avgHRV = null,
        )

        val result = AnalyticsEngine.analyzeDay(
            day = day,
            profile = profile,
            sleepNeedHours = sleepNeedHours,
            providedSleep = listOf(provided),
        ).rest
        assertNotNull(result)
        return result!!
    }

    @Test
    fun sleepNeedUsesPointOneHourFloorAtAndAcrossBoundary() {
        val cases = listOf(
            -1.0 to 29.17,
            0.0 to 29.17,
            0.099 to 29.17,
            0.1 to 29.17,
            0.101 to 29.13,
        )

        assertEquals(cases.map { it.second }, cases.map { rest(it.first) })
    }
}
