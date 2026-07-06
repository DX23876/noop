package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * #803 parity: [HrvAnalyzer.rollingRmssd], the pure windowed rMSSD the Deep Timeline plots instead of the
 * raw RR interval it used to label "HRV". Kotlin twin of the Swift HRVAnalyzer.rollingRmssd tests:
 *  1. each emitted value is a Task-Force rMSSD over the trailing window (not a raw RR), so its magnitude
 *     tracks the within-window successive-difference spread, NOT the absolute heart period;
 *  2. the SAME Malik/range artifact filter the nightly path uses is applied, so an out-of-range or ectopic
 *     beat can't enter a window;
 *  3. degrades to empty on too-few rows. Pure-JVM, no Android.
 */
class HrvAnalyzerRollingTest {

    private fun rr(ts: Long, ms: Int) = RrInterval(deviceId = "my-whoop", ts = ts, rrMs = ms)

    @Test fun emptyOnFewerThanTwoRows() {
        assertTrue(HrvAnalyzer.rollingRmssd(emptyList()).isEmpty())
        assertTrue(HrvAnalyzer.rollingRmssd(listOf(rr(0, 800))).isEmpty())
    }

    @Test fun emitsWindowedRmssdNotRawInterval() {
        // A steady ~800 ms series with a small alternation: rMSSD is small (a few ms), NOWHERE near the
        // ~800 ms raw interval the old trace plotted. This is the honesty point of the relabel.
        val series = (0 until 30).map { rr(it.toLong(), if (it % 2 == 0) 800 else 810) }
        val out = HrvAnalyzer.rollingRmssd(series, windowSec = 60)
        assertTrue("expected a curve", out.isNotEmpty())
        // Every emitted rMSSD is far below the raw interval magnitude (would be ~800 if it were raw RR).
        assertTrue(out.all { (_, v) -> v < 100.0 })
        // The alternation is +/-10 ms successive diffs, so rMSSD settles near 10 ms once the window fills.
        val last = out.last().second
        assertTrue("rMSSD should reflect the 10 ms alternation, got $last", abs(last - 10.0) < 3.0)
    }

    @Test fun timestampsAreThePerSampleWindowEnd() {
        val series = (0 until 10).map { rr(100L + it, 800) }
        val out = HrvAnalyzer.rollingRmssd(series, windowSec = 300)
        // #1035 (ryanbr): one point per sample once its trailing window holds >= minBeatsPerWindow (8)
        // clean beats, so the curve starts at the 8th sample's ts (107) — a 2-beat window was a noisy
        // spike, not HRV.
        assertEquals(107L, out.first().first)
        assertEquals(109L, out.last().first)
    }

    @Test fun stepSecThinsEmission() {
        // #1036 (ryanbr) parity with Swift testRollingRmssdStepThinsEmission: the same 60-beat 1 Hz stream
        // with a 10 s stride emits far fewer than one-per-beat, and adjacent emitted points are >= stepSec
        // apart, while the value stays the steady ~10 ms alternation. This is the flood guard the day-scale
        // chart needs (the HRV branch skips downsampleTimeline, so without a stride it plots every beat).
        val series = (0 until 60).map { rr(1000L + it, if (it % 2 == 0) 800 else 810) }
        val dense = HrvAnalyzer.rollingRmssd(series, windowSec = 30, stepSec = 0)
        val thinned = HrvAnalyzer.rollingRmssd(series, windowSec = 30, stepSec = 10)
        assertTrue("a stride must emit fewer points than every-beat", thinned.size < dense.size)
        for (i in 1 until thinned.size) {
            assertTrue("adjacent emits >= stepSec apart", thinned[i].first - thinned[i - 1].first >= 10)
        }
    }

    @Test fun rangeFilterDropsOutOfRangeBeatsFromWindows() {
        // Inject a physiologically-impossible 50 ms RR between clean beats. It must be range-filtered out,
        // so the rMSSD never sees the huge artifact jump (which would spike a raw-RR plot).
        val clean = (0 until 20).map { rr(it.toLong(), 800) }.toMutableList()
        val withArtifact = clean.toMutableList().apply { add(10, rr(100L, 50)) }
        val out = HrvAnalyzer.rollingRmssd(withArtifact, windowSec = 300)
        // A steady 800 ms series has ~0 rMSSD; if the 50 ms artifact leaked in, some window would spike.
        assertTrue("artifact must be filtered, curve stays near 0", out.all { (_, v) -> v < 5.0 })
    }

    @Test fun windowBoundsTheBeatsConsidered() {
        // Two clusters 1000 s apart, each internally steady. With a 60 s window, no window ever spans both
        // clusters, so the rMSSD stays small (never the ~big cross-cluster jump).
        val a = (0 until 25).map { rr(it.toLong(), 800) }
        val b = (0 until 25).map { rr(1000L + it, 820) }
        val out = HrvAnalyzer.rollingRmssd(a + b, windowSec = 60)
        assertTrue(out.isNotEmpty())
        assertTrue(out.all { (_, v) -> v < 30.0 })
    }

    @Test fun honestNoEmDashAndNoFabricatedValuesOnEmpty() {
        // Zero rows -> zero points (never a fabricated 0.0 reading). Guards the "honest empty" contract.
        assertTrue(HrvAnalyzer.rollingRmssd(emptyList(), windowSec = 300).isEmpty())
        // Non-positive window is rejected rather than dividing by a bad span.
        assertTrue(HrvAnalyzer.rollingRmssd((0 until 5).map { rr(it.toLong(), 800) }, windowSec = 0).isEmpty())
    }
}
