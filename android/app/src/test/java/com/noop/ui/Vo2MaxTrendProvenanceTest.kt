package com.noop.ui

import com.noop.R
import com.noop.data.Vo2MaxEstimator
import org.junit.Assert.assertEquals
import org.junit.Test

class Vo2MaxTrendProvenanceTest {
    @Test
    fun methodChangesCreateSequentialSegmentsEvenWhenMethodReturns() {
        val readings = listOf(
            VitalReading("2026-08-01", 48.0, vo2MaxAttributionSource(Vo2MaxEstimator.NES)),
            VitalReading("2026-08-08", 49.0, vo2MaxAttributionSource(Vo2MaxEstimator.NES)),
            VitalReading("2026-08-15", 63.0, vo2MaxAttributionSource(Vo2MaxEstimator.UTH)),
            VitalReading("2026-08-22", 50.0, vo2MaxAttributionSource(Vo2MaxEstimator.NES)),
        )

        assertEquals(
            listOf(
                "0:vo2max-estimator:nes",
                "0:vo2max-estimator:nes",
                "1:vo2max-estimator:uth",
                "2:vo2max-estimator:nes",
            ),
            vo2MaxTrendSegmentIds(readings),
        )
        assertEquals(
            listOf(0..1, 2..2, 3..3),
            lineChartSegmentRanges(readings.size, vo2MaxTrendSegmentIds(readings)),
        )
    }

    @Test
    fun legacyPointIsExplicitlyUnknownAndSeparatedFromKnownMethod() {
        val legacy = vo2MaxAttributionSource(null)
        assertEquals("vo2max-estimator:unknown", legacy)
        assertEquals(R.string.vo2max_method_unknown, vo2MaxAttributionLabelRes(null))
        assertEquals(R.string.vo2max_method_nes, vo2MaxAttributionLabelRes(Vo2MaxEstimator.NES))
        assertEquals(R.string.vo2max_method_uth, vo2MaxAttributionLabelRes(Vo2MaxEstimator.UTH))
        assertEquals(listOf(0..1), lineChartSegmentRanges(2, null))
    }
}
