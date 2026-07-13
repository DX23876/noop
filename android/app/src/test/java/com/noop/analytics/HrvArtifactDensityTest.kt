package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

/**
 * M1 (R-R optimization, HRV correctness): property + monotonicity of gap-aware RMSSD / pNN50 across
 * injected artifact DENSITY. Complements [HrvGapAwareTest] (which pins specific splice cases) with an
 * aggregate property swept over many seeds, so it proves a behaviour, not a single fixture.
 *
 * Construction: a clean respiratory-sinus rhythm has a known true RMSSD (it survives cleaning intact).
 * Replacing interior beats with out-of-range spikes makes the range filter remove them, splicing each
 * removed beat's two neighbours into one adjacent pair whose difference spans two true intervals. The
 * plain successive-difference RMSSD counts those splice deltas and inflates monotonically with density;
 * gap-aware marks the splices non-contiguous and skips them, staying near the artifact-free truth.
 *
 * Everything is deterministic (fixed seeds), synthetic, and needs no fixture, so it is committable and
 * runs in CI.
 */
class HrvArtifactDensityTest {

    /** ~4 min of NN at ~800 ms with respiratory sinus arrhythmia + small gaussian noise. Stays inside
     *  [300, 2000] and within 20% beat-to-beat, so cleaning leaves it untouched -> a known true RMSSD. */
    private fun trueRhythm(n: Int, seed: Long): List<Double> {
        val r = Random(seed)
        return (0 until n).map { i -> 800.0 + 35.0 * sin(2.0 * PI * i / 12.0) + r.nextGaussian() * 8.0 }
    }

    /** Replace interior beats (never the two ends) with an out-of-range spike at [density]. Each spike is
     *  removed by the range filter, splicing its neighbours -- the exact structure gap-aware must skip. */
    private fun injectDrops(rhythm: List<Double>, density: Double, seed: Long): List<Double> {
        val r = Random(seed)
        return rhythm.mapIndexed { i, v ->
            if (i in 1 until rhythm.size - 1 && r.nextDouble() < density) (if (r.nextBoolean()) 5000.0 else 150.0) else v
        }
    }

    private fun plainRmssd(raw: List<Double>): Double = HrvAnalyzer.rmssdRaw(HrvAnalyzer.cleanRR(raw)) ?: Double.NaN
    private fun gapRmssd(raw: List<Double>): Double = HrvAnalyzer.analyzeRaw(raw).rmssd ?: Double.NaN

    private val densities = listOf(0.0, 0.05, 0.10, 0.20, 0.30)
    private val seeds = 1L..40L

    @Test
    fun gapAwareErrorNeverExceedsPlainAcrossDensity() {
        val plainErr = DoubleArray(densities.size)
        val gapErr = DoubleArray(densities.size)
        for ((di, d) in densities.withIndex()) {
            var pe = 0.0; var ge = 0.0; var n = 0
            for (s in seeds) {
                val rhythm = trueRhythm(240, s)
                val truth = HrvAnalyzer.rmssdRaw(rhythm)!!
                val raw = injectDrops(rhythm, d, s * 7 + 1)
                pe += abs(plainRmssd(raw) - truth); ge += abs(gapRmssd(raw) - truth); n++
            }
            plainErr[di] = pe / n; gapErr[di] = ge / n
        }
        println("[M1] density -> plainErr=${plainErr.map { "%.2f".format(it) }}  gapErr=${gapErr.map { "%.2f".format(it) }}")
        // Core property: in aggregate gap-aware is never worse than plain at any density.
        for (i in densities.indices) {
            assertTrue("density ${densities[i]}: gapErr=${gapErr[i]} must be <= plainErr=${plainErr[i]}",
                gapErr[i] <= plainErr[i] + 1e-9)
        }
        // No artifacts -> identical to plain (no regression), both exactly the true RMSSD.
        assertEquals(0.0, plainErr[0], 1e-9)
        assertEquals(0.0, gapErr[0], 1e-9)
        // Plain visibly inflates by the top density; gap-aware stays a small fraction of that error.
        // Observed (40 seeds, 240-beat windows): plainErr ~5.2 ms vs gapErr ~0.47 ms at 30% drops.
        assertTrue("plain must inflate with artifacts: ${plainErr.toList()}", plainErr.last() > 3.0)
        assertTrue("gap-aware stays near truth: ${gapErr.toList()}", gapErr.last() < plainErr.last() * 0.5)
    }

    @Test
    fun plainInflatesMonotonicallyWhileGapAwareTracksTruth() {
        val plainMean = DoubleArray(densities.size)
        val gapMean = DoubleArray(densities.size)
        var truthMean = 0.0
        for ((di, d) in densities.withIndex()) {
            var pm = 0.0; var gm = 0.0; var tm = 0.0; var n = 0
            for (s in seeds) {
                val rhythm = trueRhythm(240, s); val truth = HrvAnalyzer.rmssdRaw(rhythm)!!
                val raw = injectDrops(rhythm, d, s * 13 + 3)
                pm += plainRmssd(raw); gm += gapRmssd(raw); tm += truth; n++
            }
            plainMean[di] = pm / n; gapMean[di] = gm / n; truthMean = tm / n
        }
        println("[M1] truth=${"%.2f".format(truthMean)}  plainMean=${plainMean.map { "%.1f".format(it) }}  gapMean=${gapMean.map { "%.1f".format(it) }}")
        // Plain RMSSD rises with density (splice inflation); gap-aware stays in a tight band around truth.
        for (i in 1 until densities.size) {
            assertTrue("plain must be non-decreasing in density: ${plainMean.toList()}", plainMean[i] >= plainMean[i - 1] - 0.5)
            assertTrue("gap-aware must track truth ($truthMean): ${gapMean.toList()}", abs(gapMean[i] - truthMean) < 0.25 * truthMean)
        }
        // Observed inflation ~1.29x truth at 30% drops; assert a clear >1.2x while gap-aware stays flat.
        assertTrue("plain clearly inflated at top density: ${plainMean.last()} vs truth $truthMean", plainMean.last() > truthMean * 1.2)
    }

    @Test
    fun pnn50GapAwareDoesNotInflateWithDrops() {
        var truePnn = 0.0; var gapPnnHigh = 0.0; var n = 0
        for (s in seeds) {
            val rhythm = trueRhythm(240, s)
            truePnn += HrvAnalyzer.analyzeRaw(rhythm).pnn50 ?: 0.0
            gapPnnHigh += HrvAnalyzer.analyzeRaw(injectDrops(rhythm, 0.30, s * 11 + 4)).pnn50 ?: 0.0
            n++
        }
        truePnn /= n; gapPnnHigh /= n
        println("[M1] pNN50 truth=${"%.2f".format(truePnn)}  gapAware@30%=${"%.2f".format(gapPnnHigh)}")
        // Gap-aware pNN50 at heavy drop density stays close to the artifact-free value (splices excluded).
        assertTrue("gap-aware pNN50 must not inflate with drops: true=$truePnn high=$gapPnnHigh", gapPnnHigh <= truePnn + 6.0)
    }
}
