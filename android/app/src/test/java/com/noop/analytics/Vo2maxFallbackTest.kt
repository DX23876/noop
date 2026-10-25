package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.Vo2MaxEstimator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * #1391: VO₂max is offered even WITHOUT a waist. `fitnessAgeRows` persists `vo2max_est` = the Nes 2011
 * waist-based estimate when a waist is set, else falls back to the Uth 2004 HR-ratio estimate
 * (15.3·HRmax/RHR, HRmax = Tanaka(age)) — so a user past the age+RHR fitness-age gate gets a VO₂max
 * instead of a blank. Twin of the Swift Vo2maxFallbackTests.
 */
class Vo2maxFallbackTest {
    // ≥ minCoverageDays (4) RHR nights + strain so the fitness-age gate can compute.
    private fun gate(rhr: Int) = (0 until 7).map {
        DailyMetric(deviceId = "my-whoop", day = "2026-08-%02d".format(9 + it), restingHr = rhr, strain = 50.0)
    }

    @Test
    fun noWaist_fallsBackToUthHrRatioEstimate() {
        val profile = UserProfile(age = 40.0, sex = "male", waistCm = 0.0)   // no waist → Nes value is null
        val rows = IntelligenceEngine.fitnessAgeRows(gate(rhr = 60), profile, "my-whoop-noop", "2026-08-15")
        val vo2 = rows.firstOrNull { it.key == "vo2max_est" }
        assertNotNull("without a waist, VO₂max must still be offered via the Uth fallback", vo2)
        // Uth: 15.3 × Tanaka(40)=180 / RHR 60 = 45.9
        assertEquals(15.3 * StrainScorer.tanakaHRmax(40.0) / 60.0, vo2!!.value, 1e-6)
    }

    @Test
    fun waistSet_usesTheNesWaistBasedEstimate() {
        val noWaist = UserProfile(age = 40.0, sex = "male", waistCm = 0.0)
        val withWaist = UserProfile(age = 40.0, sex = "male", waistCm = 90.0, heightCm = 175.0, weightKg = 80.0)
        val uth = IntelligenceEngine.fitnessAgeRows(gate(60), noWaist, "my-whoop-noop", "2026-08-15")
            .first { it.key == "vo2max_est" }.value
        val nes = IntelligenceEngine.fitnessAgeRows(gate(60), withWaist, "my-whoop-noop", "2026-08-15")
            .first { it.key == "vo2max_est" }.value
        // With a waist the persisted value is the Nes waist-based estimate (waist term present)…
        val paIndex = FitnessAgeEngine.physicalActivityIndexFromStrain(7, 50.0)
        assertEquals(FitnessAgeEngine.estimateVO2max(40.0, "male", 90.0, 60.0, paIndex), nes, 1e-6)
        // …and it is a different number from the Uth HR-ratio fallback.
        assertTrue("Nes (waist) and Uth (HR-ratio) estimates should differ", abs(nes - uth) > 0.01)
    }

    @Test
    fun newlyComputedPoint_recordsTheEstimatorUsedAtComputeTime() {
        val computedId = "my-whoop-noop"
        val noWaist = UserProfile(age = 40.0, sex = "male", waistCm = 0.0)
        val withWaist = UserProfile(age = 40.0, sex = "male", waistCm = 90.0)
        val uthRows = IntelligenceEngine.fitnessAgeRows(gate(60), noWaist, computedId, "2026-08-15")
        val nesRows = IntelligenceEngine.fitnessAgeRows(gate(60), withWaist, computedId, "2026-08-22")

        val uth = IntelligenceEngine.vo2MaxProvenance(uthRows, noWaist.waistCm, computedId).single()
        val nes = IntelligenceEngine.vo2MaxProvenance(nesRows, withWaist.waistCm, computedId).single()

        assertEquals("uth", uth.sourceId)
        assertEquals("2026-08-15", uth.day)
        assertEquals("vo2max_est", uth.key)
        assertEquals("nes", nes.sourceId)
        assertEquals(Vo2MaxEstimator.UTH, Vo2MaxEstimator.fromProvenanceId(uth.sourceId))
        assertEquals(Vo2MaxEstimator.NES, Vo2MaxEstimator.fromProvenanceId(nes.sourceId))
    }

    @Test
    fun missingLegacyProvenance_remainsUnknown() {
        assertEquals(null, Vo2MaxEstimator.fromProvenanceId(null))
        assertEquals(null, Vo2MaxEstimator.fromProvenanceId("my-whoop"))
    }
}
