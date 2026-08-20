package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset

class AnalyticsEngineRestTraceContractTest {
    private val day = "2025-06-10"

    private fun analyze(stage: String, efficiency: Double): Pair<DayResult, List<String>> {
        val start = LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond() + 3_600
        val end = start + 1_800
        val provided = DetectedSleep(
            start = start,
            end = end,
            efficiency = efficiency,
            stages = listOf(StageSegment(start, end, stage)),
            restingHR = null,
            avgHRV = null,
        )
        val lines = mutableListOf<String>()
        val result = AnalyticsEngine.analyzeDay(
            day = day,
            profile = UserProfile(),
            providedSleep = listOf(provided),
            traceSink = { lines.add(it) },
        )
        return result to lines
    }

    @Test
    fun wakeOnlySessionOmitsRestScoreAndRestTrace() {
        val result = analyze(stage = "wake", efficiency = 0.0)
        assertNull(result.first.rest)
        assertEquals(emptyList<String>(), result.second.filter { it.startsWith("rest ") })
        assertTrue(
            "non-Rest diagnostics must remain available when Rest is absent",
            result.second.contains(
                "sleep-motion day=2025-06-10 grav=0 hr=0 sparse=false stager=V1 family=whoop5",
            ),
        )
    }

    @Test
    fun positiveSleepKeepsExactRestTrace() {
        val result = analyze(stage = "light", efficiency = 1.0)
        assertEquals(28.13, result.first.rest!!, 0.0)
        assertEquals(
            listOf(
                "rest composite=28.13 dur=0.06*wDur=0.5 eff=1.0*wEff=0.2 " +
                    "restor=0.0*wRestor=0.2 deepFactor=0.5 consist=0.5*wConsist=0.1 " +
                    "group=1 groupInBedMin=30",
            ),
            result.second.filter { it.startsWith("rest ") },
        )
    }
}
