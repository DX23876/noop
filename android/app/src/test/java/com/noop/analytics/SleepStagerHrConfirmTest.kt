package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the median-vs-mean sleep-run HR confirmation ([SleepStager.confirmSleepWithHR]).
 *
 * A real sleep night carries brief arousal / wake HR spikes. The old gate compared the run's MEAN HR to
 * baseline * hrSleepBaselineMult, so those spikes could pull the mean over the bar and reject the run
 * (and, for the usual single main-sleep run, drop the WHOLE night -> "no sleep recorded"). Confirming on
 * the run MEDIAN is spike-robust and, because median <= mean for right-skewed HR, only ever RELAXES the
 * gate. These tests pin both halves of that contract: the spiky-but-truly-asleep run now survives, and a
 * genuinely elevated (awake) run is still rejected. Android twin of the Swift `SleepStagerHrConfirmTests`.
 */
class SleepStagerHrConfirmTest {

    private val dev = "d"
    private val start = 1_000_000L

    /** A run of [n] HR samples: [spikes] of them at [spikeBpm], the rest at [baseBpm], 1 Hz from [start]. */
    private fun hr(n: Int, baseBpm: Int, spikes: Int = 0, spikeBpm: Int = 190): List<HrSample> =
        (0 until n).map { i ->
            HrSample(deviceId = dev, ts = start + i, bpm = if (i < spikes) spikeBpm else baseBpm)
        }

    private fun period(durS: Long) = SleepStager.Period(stage = "sleep", start = start, end = start + durS)

    @Test
    fun spikyButAsleepRunSurvivesWhereMeanWouldDropIt() {
        // baseline 50 -> gate bar = 52.5 bpm. 600 s run: 570 s asleep at 48, 30 s of arousal at 190.
        // MEAN = (570*48 + 30*190)/600 = 55.1 bpm (over the bar -> old logic REJECTS the run).
        // MEDIAN = 48 bpm (under the bar -> the run is genuinely asleep and is KEPT).
        val seg = hr(n = 600, baseBpm = 48, spikes = 30, spikeBpm = 190)
        val mean = seg.sumOf { it.bpm }.toDouble() / seg.size
        val median = HrvAnalyzer.median(seg.map { it.bpm.toDouble() })
        val bar = 50.0 * SleepStager.hrSleepBaselineMult
        // Guard the fixture: this only tests the fix when mean is over the bar and median is under it.
        assertTrue("fixture: mean ($mean) must exceed bar ($bar)", mean > bar)
        assertTrue("fixture: median ($median) must be at/under bar ($bar)", median <= bar)

        assertTrue(
            "a spiky but truly-asleep run must be confirmed (median under bar)",
            SleepStager.confirmSleepWithHR(period(600), seg, baseline = 50.0),
        )
    }

    @Test
    fun genuinelyElevatedRunIsStillRejected() {
        // An awake run: HR sits at 60 throughout (median 60 > 52.5 bar) -> must FAIL confirmation.
        val seg = hr(n = 600, baseBpm = 60)
        assertFalse(
            "a run whose median HR is above baseline*mult must be rejected",
            SleepStager.confirmSleepWithHR(period(600), seg, baseline = 50.0),
        )
    }

    @Test
    fun runTheMeanAlreadyAcceptedStillPasses() {
        // No skew: flat 48 bpm (mean == median == 48 <= 52.5). The fix must not regress the accept path.
        val seg = hr(n = 600, baseBpm = 48)
        assertTrue(
            "a flat low-HR run accepted under mean must still pass under median",
            SleepStager.confirmSleepWithHR(period(600), seg, baseline = 50.0),
        )
    }

    @Test
    fun tooFewSamplesTrustsGravity() {
        // Below hrRefineMinSamples the HR refinement is skipped entirely -> trust gravity (return true),
        // even with an absurd HR, exactly as before the fix.
        val seg = hr(n = 10, baseBpm = 200)
        assertTrue(
            "fewer than hrRefineMinSamples must bypass the HR gate",
            SleepStager.confirmSleepWithHR(period(600), seg, baseline = 50.0),
        )
    }

    @Test
    fun nullBaselineTrustsGravity() {
        val seg = hr(n = 600, baseBpm = 200)
        assertTrue(
            "a null baseline must bypass the HR gate",
            SleepStager.confirmSleepWithHR(period(600), seg, baseline = null),
        )
    }
}
