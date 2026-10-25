package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Twin of the Swift TestReadoutTests: the Recovery / HRV live-readout tagged-tail parsers (Test Centre
 * Group G). Pure-JVM, no Robolectric.
 */
class TestReadoutTest {

    @Test fun lastChargeBreakdownParsesScoreAndBand() {
        val tail = listOf(
            "[recovery] charge day=2021-06-17 baseline hrv mean=50.0 spread=4.79 nValid=14 status=trusted",
            "[recovery] charge day=2021-06-17 score=62.5 band=yellow (logistic k=1.6 z0=-0.2)",
        )
        assertEquals("score=62.5 band=yellow", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownFallsBackToNilReason() {
        val tail = listOf(
            "[recovery] charge day=2021-06-17 nilScore reason=hrvBaselineNotUsable " +
                "hrvStatus=calibrating hrvNValid=2 (need nValid>=4)",
        )
        assertEquals("no score (hrvBaselineNotUsable)", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownNullWhenNoTrace() {
        assertNull(TestReadout.lastChargeBreakdown(emptyList()))
        assertNull(TestReadout.lastChargeBreakdown(listOf("[sleep] gate run=0 ... gate=accepted")))
    }

    @Test fun lastChargeBreakdownPicksNewestDayNotLastEmitted() {
        // #343: the engine emits days NEWEST-FIRST, so the LAST line is the OLDEST window-edge day — a
        // cold-start nilScore. The panel must show the NEWEST day's real score, not that trailing nilScore.
        val tail = listOf(
            "[recovery] charge day=2026-07-12 baseline hrv mean=44.8 spread=7.2 nValid=20 status=trusted",
            "[recovery] charge day=2026-07-12 score=99.78 band=green (logistic k=1.6 z0=-0.2)",
            "[recovery] charge day=2026-07-11 score=99.36 band=green (logistic k=1.6 z0=-0.2)",
            "[recovery] charge day=2026-07-09 nilScore reason=missingInput (hrv/rhr/hrvBaseline required)",
        )
        assertEquals("score=99.78 band=green", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownReportsNilWhenNewestDayGenuinelyMissing() {
        // If the NEWEST day itself has no score (real missing input today), report THAT — don't fall
        // through to an older day's score and present a stale number as current.
        val tail = listOf(
            "[recovery] charge day=2026-07-12 nilScore reason=missingInput (hrv/rhr/hrvBaseline required)",
            "[recovery] charge day=2026-07-11 score=88.0 band=green (logistic k=1.6 z0=-0.2)",
        )
        assertEquals("no score (missingInput)", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastChargeBreakdownPrefersLastPassForNewestDay() {
        // Several recompute passes may be in the tail; the newest day's latest pass wins.
        val tail = listOf(
            "[recovery] charge day=2026-07-12 score=50.0 band=yellow (..)",  // pass 1
            "[recovery] charge day=2026-07-11 score=40.0 band=yellow (..)",
            "[recovery] charge day=2026-07-12 score=72.0 band=green (..)",   // pass 2, newest day refreshed
            "[recovery] charge day=2026-07-11 score=41.0 band=yellow (..)",
        )
        assertEquals("score=72.0 band=green", TestReadout.lastChargeBreakdown(tail))
    }

    @Test fun lastHrvComputationParsesRmssdFragment() {
        val tail = listOf(
            "[hrv] hrv path=spot nInput=60 nClean=58 rejectedFraction=0.03",
            "[hrv] hrv rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms",
        )
        assertEquals("rmssd=42.1ms sdnn=55.3ms meanNN=812.0ms", TestReadout.lastHrvComputation(tail))
    }

    @Test fun lastHrvComputationReportsFilteredOut() {
        val tail = listOf("[hrv] hrv result=nil (a gate above refused the reading)")
        assertEquals("no reading (filtered out)", TestReadout.lastHrvComputation(tail))
    }
}
