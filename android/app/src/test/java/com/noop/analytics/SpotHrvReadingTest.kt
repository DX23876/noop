package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * [SpotHrvReading] — the on-demand "take an HRV reading now" spot RMSSD path (#537).
 *
 * The headline guarantee these tests pin is CONSISTENCY: the spot value uses the SAME RMSSD math as
 * NOOP's nightly HRV ([HrvAnalyzer.rmssdRaw], Task Force 1996, sample (n-1) denominator), so a spot
 * reading is comparable to the overnight number, not a few percent off it. We assert the value against
 * a hand-computed (n-1) RMSSD on a known RR series, and against [HrvAnalyzer] directly.
 */
class SpotHrvReadingTest {

    /** Textbook RMSSD with the Task Force (1996) SAMPLE denominator (n-1) — the reference NOOP uses. */
    private fun rmssdSampleDenom(rr: List<Double>): Double {
        var sumSq = 0.0
        for (i in 1 until rr.size) {
            val d = rr[i] - rr[i - 1]
            sumSq += d * d
        }
        return sqrt(sumSq / (rr.size - 1))
    }

    /** A clean, in-range RR series long enough to clear MIN_BEATS, with small beat-to-beat variation. */
    private fun knownCleanSeries(): List<Int> {
        // 24 intervals around 850 ms (~70 bpm), alternating +/-20 ms so successive diffs are well-defined
        // and every value sits inside [300, 2000] ms so the range filter keeps them all.
        val out = ArrayList<Int>()
        var base = 850
        for (i in 0 until 24) {
            out.add(base + if (i % 2 == 0) 20 else -20)
        }
        return out
    }

    @Test
    fun spotRmssdMatchesHandComputedSampleDenominator() {
        val rr = knownCleanSeries()
        val outcome = SpotHrvReading.compute(rr)
        assertTrue("a clean 24-beat series must produce a reading", outcome is SpotHrvReading.Outcome.Reading)
        val reading = outcome as SpotHrvReading.Outcome.Reading

        // The series has no ectopics (alternating +/-20 around the median is within the 20% Malik gate),
        // so all 24 survive cleaning and the (n-1) RMSSD over them is the reference.
        val expected = rmssdSampleDenom(rr.map { it.toDouble() })
        assertEquals("spot RMSSD must equal the (n-1) reference", expected, reading.rmssdMs, 1e-9)
        assertEquals("all 24 clean beats used", 24, reading.beats)
    }

    @Test
    fun spotRmssdEqualsHrvAnalyzerNightlyMath() {
        // The spot path MUST agree with the canonical analyzer the nightly avgHrv is built on, beat for
        // beat — that is the whole consistency requirement of this lane.
        val rr = knownCleanSeries()
        val viaAnalyzer = HrvAnalyzer.analyzeRaw(rr.map { it.toDouble() }).rmssd
        assertNotNull(viaAnalyzer)
        val viaSpot = (SpotHrvReading.compute(rr) as SpotHrvReading.Outcome.Reading).rmssdMs
        assertEquals(viaAnalyzer!!, viaSpot, 1e-12)
    }

    @Test
    fun usesTaskForceSampleDenominator() {
        // RMSSD divides the summed squared successive diffs by the SAMPLE NN count minus one (n-1),
        // which for a contiguous clean series equals the number of diffs. The guard here is that the
        // spot path reproduces the Task Force form exactly (a from-scratch port that divided by a
        // different count would fail this), and that the same number flows through to the analyzer.
        val rr = knownCleanSeries().map { it.toDouble() }
        var sumSq = 0.0
        for (i in 1 until rr.size) { val d = rr[i] - rr[i - 1]; sumSq += d * d }
        val taskForce = sqrt(sumSq / (rr.size - 1)) // divide by NN-1

        val spot = (SpotHrvReading.compute(knownCleanSeries()) as SpotHrvReading.Outcome.Reading).rmssdMs
        assertEquals(taskForce, spot, 1e-9)
        assertEquals(rmssdSampleDenom(rr), spot, 1e-9)
    }

    @Test
    fun tooFewCleanBeatsIsHonestlyInsufficientNotFabricated() {
        // Only a handful of beats — below MIN_BEATS — must yield Insufficient, never a number.
        val outcome = SpotHrvReading.compute(listOf(850, 870, 840, 860, 855))
        assertTrue(outcome is SpotHrvReading.Outcome.Insufficient)
        val insuff = outcome as SpotHrvReading.Outcome.Insufficient
        assertEquals(HrvAnalyzer.MIN_BEATS, insuff.needed)
        assertTrue("fewer clean beats than needed", insuff.clean < insuff.needed)
    }

    @Test
    fun outOfRangeIntervalsAreBoundsCheckedAway() {
        // Untrusted BLE input: garbage intervals (0, negative, absurdly large) must be filtered by the
        // analyzer's range gate, leaving too few clean beats -> Insufficient (no crash, no fabrication).
        val junk = listOf(0, -5, 50_000, 999_999, 12)
        val outcome = SpotHrvReading.compute(junk)
        assertTrue(outcome is SpotHrvReading.Outcome.Insufficient)
    }

    @Test
    fun emptyInputIsInsufficient() {
        val outcome = SpotHrvReading.compute(emptyList())
        assertTrue(outcome is SpotHrvReading.Outcome.Insufficient)
        assertEquals(0, (outcome as SpotHrvReading.Outcome.Insufficient).clean)
    }

    @Test
    fun spotGateRefusesNoisyCaptureByDefault() {
        // #585: a capture where too many beats were noise must be refused even though >= MIN_BEATS clean
        // beats survive. 24 valid 850 ms + 16 out-of-range (10 ms) -> 16/40 = 0.40 rejected > the default
        // 0.35 ceiling -> Insufficient (an honest "sit still and try again"), never a fabricated number.
        val rr = knownCleanSeries() + List(16) { 10 }   // 24 clean + 16 out-of-range
        val outcome = SpotHrvReading.compute(rr)
        assertTrue("0.40 rejected must be refused by the default spot gate",
            outcome is SpotHrvReading.Outcome.Insufficient)
        val insuff = outcome as SpotHrvReading.Outcome.Insufficient
        assertEquals(HrvAnalyzer.MIN_BEATS, insuff.needed)
        assertEquals(40, insuff.input)
        assertEquals(0, insuff.clean)   // refusal reports the empty result's nClean
    }

    @Test
    fun spotGateRelaxedAllowsTheSameNoisyCapture() {
        // Passing a permissive ceiling (> 0.40) lets the same 24-clean capture through — proving the gate,
        // not the clean-beat count, is what refused it above.
        val rr = knownCleanSeries() + List(16) { 10 }
        val outcome = SpotHrvReading.compute(rr, maxRejectedFraction = 0.5)
        assertTrue("a 0.5 ceiling must allow the 0.40-rejected capture",
            outcome is SpotHrvReading.Outcome.Reading)
        assertEquals(24, (outcome as SpotHrvReading.Outcome.Reading).beats)
    }

    @Test
    fun meanHrFromNnMatchesDefinition() {
        assertEquals(60.0, SpotHrvReading.meanHrFromNN(1000.0)!!, 1e-9)
        assertEquals(75.0, SpotHrvReading.meanHrFromNN(800.0)!!, 1e-9)
        assertNull(SpotHrvReading.meanHrFromNN(null))
        assertNull(SpotHrvReading.meanHrFromNN(0.0))
        assertNull(SpotHrvReading.meanHrFromNN(-1.0))
    }

    @Test
    fun caveatIsSourceAwareAndClean() {
        val ppg = SpotHrvReading.caveatFor(SpotHrvReading.Source.OPTICAL_PPG)
        val strap = SpotHrvReading.caveatFor(SpotHrvReading.Source.CHEST_STRAP)
        val unknown = SpotHrvReading.caveatFor(SpotHrvReading.Source.UNKNOWN)

        // PPG caveat must call out the noisier optical source; chest strap must not.
        assertTrue("PPG caveat mentions the optical pulse signal", ppg.contains("optical pulse signal"))
        assertTrue("chest-strap caveat omits the PPG note", !strap.contains("optical pulse signal"))
        assertEquals("unknown source uses the base caveat", strap, unknown)

        // Every caveat states the universal "spot, not overnight baseline" limit.
        for (c in listOf(ppg, strap, unknown)) {
            assertTrue("states it is a spot reading", c.contains("spot reading"))
            assertTrue("states it is not the overnight baseline", c.contains("overnight HRV baseline"))
            // House rule: no em-dashes anywhere in user-facing copy.
            assertTrue("no em-dash in caveat", !c.contains("—"))
        }
    }
}
