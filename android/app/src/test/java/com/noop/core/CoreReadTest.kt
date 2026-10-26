package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CoreReadTest {
    /** The literal the Swift core writes for this day (NoopCore CoreReadTests pins the same text). */
    private val dayJson = """{"charge":72,"day":"2026-10-02","deepMinutes":80,"efficiency":0.9,"effort":42,"hrv":62,"lightMinutes":230,"remMinutes":90,"rest":88,"restingHr":52,"sleepMinutes":402}"""

    @Test fun aDayReadsEveryValueAndLeavesMissingOnesNull() {
        val day = CoreRead.parseDay(dayJson)!!
        assertEquals("2026-10-02", day.day)
        assertEquals(72.0, day.charge!!, 0.0)
        assertEquals(88.0, day.rest!!, 0.0)
        assertEquals(52, day.restingHr)
        assertEquals(402.0, day.sleepMinutes!!, 0.0)
        assertNull(day.spo2)
        assertNull(day.steps)
    }

    @Test fun noDayIsNull() {
        assertNull(CoreRead.parseDay("null"))
    }

    @Test fun nightsKeepTheirStages() {
        val nights = CoreRead.parseNights(
            """[{"edited":false,"efficiency":0.9,"endTs":2000,"stages":[{"end":1500,"stage":"deep","start":1000}],"startTs":1000}]""")
        assertEquals(1, nights.size)
        assertEquals(CoreRead.Night.Stage("deep", 1000, 1500), nights[0].stages.single())
        assertNull(nights[0].hrv)
    }

    @Test fun aNightCarriesItsStageMinutes() {
        val night = CoreRead.parseNights(
            """[{"edited":false,"endTs":2000,"minutes":{"deep":80,"light":200,"rem":90,"wake":20},"stages":[],"startTs":1000}]""")
            .single()
        assertEquals(mapOf("wake" to 20.0, "light" to 200.0, "deep" to 80.0, "rem" to 90.0), night.minutes)
        // An imported night has totals without a timeline; the Sleep screen states the totals.
        val summary = com.noop.ui.forge.SleepSummary.of(night)
        assertEquals(390, summary.inBedMin)
        assertEquals(370, summary.asleepMin)
        assertEquals(170, summary.restorativeMin)
    }

    @Test fun aSeriesKeepsItsOrder() {
        assertEquals(listOf(CoreRead.Point("2026-10-01", 61.0), CoreRead.Point("2026-10-02", 62.5)),
            CoreRead.parseSeries("""[{"day":"2026-10-01","value":61},{"day":"2026-10-02","value":62.5}]"""))
    }

    @Test fun aHeartRateTraceKeepsItsTimesAndMeans() {
        assertEquals(listOf(CoreRead.HeartPoint(1_800_000_000, 52.5), CoreRead.HeartPoint(1_800_000_300, 61.0)),
            CoreRead.parseHeartRate("""[{"bpm":52.5,"ts":1800000000},{"bpm":61,"ts":1800000300}]"""))
    }
}
