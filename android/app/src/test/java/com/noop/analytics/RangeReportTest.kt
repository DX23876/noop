package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Faithful Kotlin port of
 * Packages/StrandAnalytics/Tests/StrandAnalyticsTests/RangeReportTests.swift.
 * Same fixtures, same assertions — cross-platform parity is the contract.
 */
class RangeReportTest {

    private val recoveryRamp = mapOf(
        "2026-06-01" to 40.0,
        "2026-06-02" to 50.0,
        "2026-06-03" to 60.0,
        "2026-06-04" to 70.0,
    )

    // Known series → correct mean / min / max / halves / trend

    @Test
    fun knownSeriesStats() {
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertEquals("2026-06-01", report.start)
        assertEquals("2026-06-04", report.end)
        assertEquals(4, report.totalDays)
        assertFalse(report.isEmpty)

        val s = report.stat(ReportMetric.RECOVERY)!!
        assertEquals(4, s.n)
        assertEquals(55.0, s.mean, 1e-9)
        assertEquals(45.0, s.firstHalfMean, 1e-9)
        assertEquals(65.0, s.secondHalfMean, 1e-9)
        assertEquals(20.0, s.halfDelta, 1e-9)
        assertEquals(ReportTrend.RISING, s.trend)
        assertEquals("2026-06-04", s.latest.day)
        assertEquals(70.0, s.latest.value, 1e-9)
    }

    // Min / max carry the right day

    @Test
    fun minMaxCarryRightDay() {
        val series = mapOf(
            "2026-06-01" to 55.0,
            "2026-06-02" to 40.0,   // min
            "2026-06-03" to 70.0,   // max
            "2026-06-04" to 50.0,
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.HRV to series),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.HRV)!!
        assertEquals("2026-06-02", s.min.day)
        assertEquals(40.0, s.min.value, 1e-9)
        assertEquals("2026-06-03", s.max.day)
        assertEquals(70.0, s.max.value, 1e-9)
    }

    // Missing metric is omitted

    @Test
    fun missingMetricOmitted() {
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertNotNull(report.stat(ReportMetric.RECOVERY))
        assertNull(report.stat(ReportMetric.STRAIN))
        assertNull(report.stat(ReportMetric.HRV))
        assertNull(report.stat(ReportMetric.RESTING_HR))
        assertNull(report.stat(ReportMetric.SLEEP_HOURS))
        assertEquals(1, report.metrics.size)
    }

    // Out-of-range days are excluded

    @Test
    fun outOfRangeDaysExcluded() {
        val series = mapOf(
            "2026-05-31" to 99.0,   // before start — excluded
            "2026-06-01" to 50.0,
            "2026-06-02" to 60.0,
            "2026-06-05" to 99.0,   // after end — excluded
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to series),
            start = "2026-06-01", end = "2026-06-02",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(2, s.n)
        assertEquals(55.0, s.mean, 1e-9)
        assertEquals(50.0, s.min.value, 1e-9)
        assertEquals(60.0, s.max.value, 1e-9)
    }

    // Single-day range

    @Test
    fun singleDayRange() {
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to mapOf("2026-06-01" to 50.0)),
            start = "2026-06-01", end = "2026-06-01",
        )
        assertEquals(1, report.totalDays)
        val s = report.stat(ReportMetric.RECOVERY)!!
        assertEquals(1, s.n)
        assertEquals(50.0, s.mean, 1e-9)
        assertEquals("2026-06-01", s.min.day)
        assertEquals("2026-06-01", s.max.day)
        assertEquals("2026-06-01", s.latest.day)
        assertEquals(50.0, s.firstHalfMean, 1e-9)
        assertEquals(50.0, s.secondHalfMean, 1e-9)
        assertEquals(ReportTrend.FLAT, s.trend)
    }

    // Empty → empty report

    @Test
    fun emptyMetricsGivesEmptyReport() {
        val report = RangeReportEngine.build(
            metrics = emptyMap(),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertTrue(report.isEmpty)
        assertEquals(0, report.metrics.size)
        assertEquals(0, report.headlines.size)
        assertEquals(4, report.totalDays)   // the WINDOW is still 4 days wide
    }

    @Test
    fun allSeriesOutOfRangeGivesEmptyReport() {
        val series = mapOf("2026-01-01" to 50.0, "2026-12-31" to 60.0)
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to series),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertTrue(report.isEmpty)
    }

    // Inverted range

    @Test
    fun invertedRangeIsEmpty() {
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-04", end = "2026-06-01",
        )
        assertTrue(report.isEmpty)
        assertEquals(0, report.totalDays)
    }

    // Trend rising / falling / flat thresholds

    @Test
    fun trendRising() {
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(ReportTrend.RISING, s.trend)
    }

    @Test
    fun trendFalling() {
        val falling = mapOf(
            "2026-06-01" to 70.0,
            "2026-06-02" to 60.0,
            "2026-06-03" to 50.0,
            "2026-06-04" to 40.0,
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to falling),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(ReportTrend.FALLING, s.trend)
    }

    @Test
    fun trendFlatWhenLevel() {
        val level = mapOf(
            "2026-06-01" to 60.0,
            "2026-06-02" to 60.0,
            "2026-06-03" to 60.0,
            "2026-06-04" to 60.0,
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to level),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(ReportTrend.FLAT, s.trend)
    }

    @Test
    fun trendFlatWhenSlopeBelowThreshold() {
        // recovery threshold is 0.5 pts/day. A +0.1/day drift is noise → flat.
        val drift = mapOf(
            "2026-06-01" to 60.0,
            "2026-06-02" to 60.1,
            "2026-06-03" to 60.2,
            "2026-06-04" to 60.3,
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to drift),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(ReportTrend.FLAT, s.trend)
    }

    // Trend uses the metric's OWN threshold

    @Test
    fun trendThresholdIsPerMetric() {
        // A +0.1/day climb is FLAT for recovery (thr 0.5) but RISING for sleepHours
        // (thr 0.05), proving the threshold is metric-specific.
        val drift = mapOf(
            "2026-06-01" to 7.0,
            "2026-06-02" to 7.1,
            "2026-06-03" to 7.2,
            "2026-06-04" to 7.3,
        )
        val recov = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to drift),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.RECOVERY)!!
        val sleep = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.SLEEP_HOURS to drift),
            start = "2026-06-01", end = "2026-06-04",
        ).stat(ReportMetric.SLEEP_HOURS)!!
        assertEquals(ReportTrend.FLAT, recov.trend)
        assertEquals(ReportTrend.RISING, sleep.trend)
    }

    // Odd count: second half gets the extra day

    @Test
    fun oddCountSplitsToSecondHalf() {
        val series = mapOf(
            "2026-06-01" to 50.0,
            "2026-06-02" to 60.0,
            "2026-06-03" to 70.0,
        )
        val s = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to series),
            start = "2026-06-01", end = "2026-06-03",
        ).stat(ReportMetric.RECOVERY)!!
        assertEquals(50.0, s.firstHalfMean, 1e-9)
        assertEquals(65.0, s.secondHalfMean, 1e-9)
    }

    // Multiple metrics + headlines

    @Test
    fun multipleMetricsAndHeadlines() {
        val recovery = mapOf(
            "2026-06-01" to 40.0, "2026-06-02" to 50.0,
            "2026-06-03" to 60.0, "2026-06-04" to 70.0,
        )
        val rhr = mapOf(   // resting HR rising = a bad sign
            "2026-06-01" to 50.0, "2026-06-02" to 52.0,
            "2026-06-03" to 54.0, "2026-06-04" to 56.0,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recovery, ReportMetric.RESTING_HR to rhr),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertEquals(2, report.metrics.size)
        assertEquals(2, report.headlines.size)
        // Recovery half-move (45→65, +20) dwarfs RHR's (51→55, +4) → ranked first.
        assertTrue(report.headlines[0].contains("Recovery"))
        assertTrue(report.headlines[0].contains("good sign"))
        // RHR rose, and higher RHR is worse → "worth a look".
        assertTrue(report.headlines[1].contains("Resting HR"))
        assertTrue(report.headlines[1].contains("worth a look"))
    }

    // Respiratory rate (lower is better; a rising trend is "worth a look")

    @Test
    fun respiratoryRateRisingIsWorthALook() {
        // A +0.5 br/min/day climb (thr 0.1) → rising. Higher resting resp = worse.
        val resp = mapOf(
            "2026-06-01" to 14.0, "2026-06-02" to 14.5,
            "2026-06-03" to 15.0, "2026-06-04" to 15.5,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RESP_RATE to resp),
            start = "2026-06-01", end = "2026-06-04",
        )
        val s = report.stat(ReportMetric.RESP_RATE)!!
        assertEquals(ReportTrend.RISING, s.trend)
        assertEquals(14.75, s.mean, 1e-9)
        assertEquals("br/min", ReportMetric.RESP_RATE.unit)
        assertFalse(ReportMetric.RESP_RATE.higherIsBetter)   // lower resting resp is better
        assertTrue(report.headlines[0].contains("Respiratory rate"))
        assertTrue(report.headlines[0].contains("worth a look")) // rose + lower-is-better
    }

    // Skin-temp Δ is valence-free (no good/bad framing, even on a clear trend)

    @Test
    fun skinTempDeviationHasNoGoodBadFrame() {
        // A +0.1 °C/day climb (thr 0.03) → clearly rising, but skin-temp Δ carries no
        // inherent good/bad direction, so the headline states the move WITHOUT a verdict.
        val skin = mapOf(
            "2026-06-01" to 0.0, "2026-06-02" to 0.1,
            "2026-06-03" to 0.2, "2026-06-04" to 0.3,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.SKIN_TEMP_DEV to skin),
            start = "2026-06-01", end = "2026-06-04",
        )
        val s = report.stat(ReportMetric.SKIN_TEMP_DEV)!!
        assertEquals(ReportTrend.RISING, s.trend)
        assertEquals("°C", ReportMetric.SKIN_TEMP_DEV.unit)
        assertFalse(ReportMetric.SKIN_TEMP_DEV.framesGoodBad)
        val line = report.headlines[0]
        assertTrue(line.contains("Skin temp"))
        assertTrue(line.contains("trending up"))
        assertFalse(line.contains("good sign"))              // no verdict either way
        assertFalse(line.contains("worth a look"))
    }

    // Workouts + Stress rows (#457)

    /**
     * Both new rows appear, and they LEAD the report in the requested order: Workouts
     * first, then Stress, ahead of every physiological metric.
     */
    @Test
    fun workoutsAndStressRowsLeadInOrder() {
        val workouts = mapOf(
            "2026-06-01" to 0.0, "2026-06-02" to 1.0, "2026-06-03" to 1.0, "2026-06-04" to 2.0,
        )
        val stress = mapOf(
            "2026-06-01" to 1.0, "2026-06-02" to 1.2, "2026-06-03" to 1.4, "2026-06-04" to 1.6,
        )
        val recovery = mapOf(
            "2026-06-01" to 40.0, "2026-06-02" to 50.0, "2026-06-03" to 60.0, "2026-06-04" to 70.0,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(
                ReportMetric.WORKOUTS to workouts,
                ReportMetric.STRESS to stress,
                ReportMetric.RECOVERY to recovery,
            ),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertNotNull(report.stat(ReportMetric.WORKOUTS))
        assertNotNull(report.stat(ReportMetric.STRESS))
        // metrics is emitted in allCases order → Workouts, then Stress, then Recovery.
        assertEquals(
            listOf(ReportMetric.WORKOUTS, ReportMetric.STRESS, ReportMetric.RECOVERY),
            report.metrics.map { it.metric },
        )
    }

    /** Workouts is valence-free: a clear trend states the move WITHOUT a good/bad verdict. */
    @Test
    fun workoutsRowHasNoGoodBadFrame() {
        // +1 workout/day vs the 0.03 threshold → rising, but logging more sessions carries no
        // inherent good/bad valence, so the headline omits a verdict.
        val workouts = mapOf(
            "2026-06-01" to 0.0, "2026-06-02" to 1.0, "2026-06-03" to 2.0, "2026-06-04" to 3.0,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.WORKOUTS to workouts),
            start = "2026-06-01", end = "2026-06-04",
        )
        val s = report.stat(ReportMetric.WORKOUTS)!!
        assertEquals(ReportTrend.RISING, s.trend)
        assertEquals(1.5, s.mean, 1e-9)
        assertEquals("/day", ReportMetric.WORKOUTS.unit)
        assertFalse(ReportMetric.WORKOUTS.framesGoodBad)
        val line = report.headlines[0]
        assertTrue(line.contains("Workouts"))
        assertTrue(line.contains("trending up"))
        assertFalse(line.contains("good sign"))
        assertFalse(line.contains("worth a look"))
    }

    /** Stress: lower is better, so a rising daily stress score reads as "worth a look". */
    @Test
    fun stressRisingIsWorthALook() {
        // +0.2/day vs the 0.02 threshold → rising. Higher stress is worse.
        val stress = mapOf(
            "2026-06-01" to 1.0, "2026-06-02" to 1.2, "2026-06-03" to 1.4, "2026-06-04" to 1.6,
        )
        val report = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.STRESS to stress),
            start = "2026-06-01", end = "2026-06-04",
        )
        val s = report.stat(ReportMetric.STRESS)!!
        assertEquals(ReportTrend.RISING, s.trend)
        assertEquals(1.3, s.mean, 1e-9)
        assertEquals("", ReportMetric.STRESS.unit)
        assertTrue(ReportMetric.STRESS.usesOneDecimal)       // 0–3 score shown to one decimal
        assertFalse(ReportMetric.STRESS.higherIsBetter)      // calmer is better
        assertTrue(report.headlines[0].contains("Stress"))
        assertTrue(report.headlines[0].contains("worth a look")) // rose + lower-is-better
    }

    // Determinism

    @Test
    fun deterministic() {
        val a = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-01", end = "2026-06-04",
        )
        val b = RangeReportEngine.build(
            metrics = mapOf(ReportMetric.RECOVERY to recoveryRamp),
            start = "2026-06-01", end = "2026-06-04",
        )
        assertEquals(a, b)
    }
}
