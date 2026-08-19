package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.OuraRespScale
import com.noop.data.RespSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.abs

/**
 * A strap that MEASURES its own respiratory rate (the Oura ring's 0x6A `breath`) supplies the night's
 * `respRateBpm` instead of NOOP's RSA-from-R-R estimate — and the personal baseline that value feeds is
 * scoped to the current device era, so a strap switch is not read as physiology. Swift twin:
 * `VendorRespRateTests`.
 */
class VendorRespRateTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private val ring = "oura-2H3B2405003655"
    private val day = "2026-08-14"
    private val dayStart = LocalDate.parse("2026-08-14").atStartOfDay(ZoneOffset.UTC).toEpochSecond()

    // ── fixtures ─────────────────────────────────────────────────────────────────────────────────────

    private fun nightStreams(start: Long, end: Long): Pair<List<HrSample>, List<RrInterval>> {
        val hr = (start until end step 30).map { HrSample("t", it, 52 + ((it / 300) % 4).toInt()) }
        var i = 0
        val rr = (start until end step 2).map { RrInterval("t", it, 1080 + (i++ % 6) * 8) }
        return hr to rr
    }

    private fun hypnogram(start: Long): List<StageSegment> {
        var t = start
        fun seg(mins: Int, stage: String): StageSegment {
            val s = StageSegment(t, t + mins * 60L, stage); t += mins * 60L; return s
        }
        return listOf(
            seg(20, "wake"), seg(100, "light"), seg(60, "deep"), seg(60, "light"),
            seg(60, "rem"), seg(120, "light"), seg(60, "deep"), seg(60, "rem"),
            seg(40, "light"), seg(20, "wake"),
        )
    }

    /**
     * Ring respiration rows at [everyS] spacing across `[start, start + durationS)`, cycling through the
     * 0.125-step values a real night holds.
     */
    private fun ringRows(
        start: Long,
        durationS: Long,
        everyS: Long = 296,
        bpms: List<Double> = listOf(14.25, 14.5, 14.625, 14.75, 15.0),
    ): List<RespSample> = (0 until durationS step everyS).mapIndexed { i, off ->
        RespSample(ring, start + off, OuraRespScale.milliBpm(bpms[i % bpms.size]))
    }

    // ── The nightly value ────────────────────────────────────────────────────────────────────────────

    @Test
    fun nightlyValueIsTheMedianOfTheInSessionRows() {
        val start = 1_754_000_000L
        val rows = ringRows(start, 8 * 3_600L)
        val v = AnalyticsEngine.vendorRespRateBpm(rows, listOf(start to start + 8 * 3_600L))
        assertNotNull(v)
        assertEquals(14.625, v!!, 1e-9)
    }

    /** Rows outside the in-bed window are not part of the night. A daytime tail must not drag it. */
    @Test
    fun rowsOutsideTheSessionAreIgnored() {
        val start = 1_754_000_000L
        val night = ringRows(start, 8 * 3_600L, bpms = listOf(14.5))
        val daytime = ringRows(start + 12 * 3_600L, 4 * 3_600L, bpms = listOf(22.0))
        val v = AnalyticsEngine.vendorRespRateBpm(night + daytime, listOf(start to start + 8 * 3_600L))
        assertEquals(14.5, v!!, 1e-9)
    }

    /**
     * A fragment of a night is not a night. The ledger's two thin captures (0.6 h and 2.0 h of coverage)
     * are exactly the rows that must not enter a personal baseline as though they described the night —
     * the gate is on SPAN, not on row count, because the record cadence is not constant.
     */
    @Test
    fun aFragmentOfANightIsRefused() {
        val start = 1_754_000_000L
        val session = start to start + 8 * 3_600L
        val dense = ringRows(start + 7 * 3_600L, 36 * 60L, everyS = 30)
        assertTrue("fixture sanity: row COUNT alone would pass any count gate", dense.size > 60)
        assertNull(AnalyticsEngine.vendorRespRateBpm(dense, listOf(session)))

        val twoHours = ringRows(start + 6 * 3_600L, 2 * 3_600L)
        assertNotNull(AnalyticsEngine.vendorRespRateBpm(twoHours, listOf(session)))
    }

    /** One corrupt record can never publish an impossible rate. */
    @Test
    fun anImplausibleMedianIsRefused() {
        val start = 1_754_000_000L
        val rows = ringRows(start, 8 * 3_600L, bpms = listOf(31.875))   // the wire's ceiling
        assertNull(AnalyticsEngine.vendorRespRateBpm(rows, listOf(start to start + 8 * 3_600L)))
    }

    @Test
    fun noRowsAndNoSessionsYieldNothing() {
        val start = 1_754_000_000L
        assertNull(AnalyticsEngine.vendorRespRateBpm(emptyList(), listOf(start to start + 3_600L)))
        assertNull(AnalyticsEngine.vendorRespRateBpm(ringRows(start, 8 * 3_600L), emptyList()))
    }

    // ── Through analyzeDay, on the night shape a ring actually produces ──────────────────────────────

    @Test
    fun analyzeDayPrefersTheDeviceMeasuredRate() {
        val sleepStart = dayStart - 4 * 3_600L
        val sleepEnd = sleepStart + 600 * 60L
        val (hr, rr) = nightStreams(sleepStart, sleepEnd)
        val provided = listOf(
            DetectedSleep(sleepStart, sleepEnd, 0.75, hypnogram(sleepStart), restingHR = null, avgHRV = null),
        )
        val rows = ringRows(sleepStart, 600 * 60L)

        val withVendor = AnalyticsEngine.analyzeDay(
            day = day, hr = hr, rr = rr, vendorResp = rows, profile = profile, providedSleep = provided,
        )
        assertEquals(14.625, withVendor.daily.respRateBpm!!, 1e-9)

        val without = AnalyticsEngine.analyzeDay(
            day = day, hr = hr, rr = rr, profile = profile, providedSleep = provided,
        )
        assertTrue(
            "without the rows the day must not report the device rate",
            without.daily.respRateBpm == null || abs(without.daily.respRateBpm!! - 14.625) > 1e-9,
        )
    }

    /** Passing no vendor rows leaves the day byte-identical to omitting the parameter. */
    @Test
    fun emptyVendorRespIsByteIdenticalToOmitting() {
        val sleepStart = dayStart - 4 * 3_600L
        val (hr, rr) = nightStreams(sleepStart, sleepStart + 600 * 60L)
        val provided = listOf(
            DetectedSleep(sleepStart, sleepStart + 600 * 60L, 0.75, hypnogram(sleepStart),
                restingHR = null, avgHRV = null),
        )
        val omitted = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, profile = profile,
            providedSleep = provided)
        val empty = AnalyticsEngine.analyzeDay(day = day, hr = hr, rr = rr, vendorResp = emptyList(),
            profile = profile, providedSleep = provided)
        assertEquals(omitted.daily, empty.daily)
    }

    // ── The baseline the value feeds ─────────────────────────────────────────────────────────────────

    /**
     * The composition IntelligenceEngine performs, pinned here because the wiring itself lives in the app
     * module's engine: a respiration history that crosses brands must fold from the CURRENT era only. A
     * WHOOP export reports ~16.1 and the ring ~14.6; pooled, the switch reads as a multi-sigma drop — a
     * device artifact scored as physiology.
     */
    @Test
    fun respBaselineFoldsTheCurrentDeviceEraOnly() {
        val cfg = Baselines.metricCfg["resp"]!!
        val dayKeys = ArrayList<String>()
        val values = ArrayList<Double?>()
        val sources = ArrayList<Pair<String, String>>()
        for (i in 0 until 30) {
            val d = "2026-07-%02d".format(i + 1)
            val isRing = i >= 20
            dayKeys.add(d)
            values.add(if (isRing) 14.6 else 16.1)
            sources.add(d to if (isRing) ring else "my-whoop")
        }
        val epoch = Baselines.deviceEraEpoch(sources)
        assertTrue("a brand switch must open a new era", epoch > 0.0)

        val scoped = Baselines.foldHistory(values, dayKeys, cfg, epoch)
        val pooled = Baselines.foldHistory(values, dayKeys, cfg, 0.0)
        assertEquals("the era-scoped baseline sits on the ring's own nights", 14.6, scoped.baseline, 0.05)
        assertTrue(
            "the pooled baseline is dragged up by the previous strap — the defect",
            pooled.baseline > scoped.baseline + 0.2,
        )
        assertTrue(abs(Baselines.deviation(14.6, scoped).z) < 1.0)
        assertTrue(abs(Baselines.deviation(14.6, pooled).z) > 1.0)
    }

    /** A single-brand history is untouched: every WHOOP-origin id buckets to one brand. */
    @Test
    fun aSingleBrandHistoryIsUnscoped() {
        val days = (1..30).map {
            "2026-07-%02d".format(it) to if (it % 2 == 0) "my-whoop" else "my-whoop-noop"
        }
        assertEquals(0.0, Baselines.deviceEraEpoch(days), 0.0)
    }
}
