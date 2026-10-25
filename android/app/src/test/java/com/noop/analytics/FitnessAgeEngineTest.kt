package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

/** Mirror of the Swift FitnessAgeEngineTests — identical inputs and expected numbers (parity guard). */
class FitnessAgeEngineTest {

    @Test fun vo2maxMen() =
        assertEquals(46.275, FitnessAgeEngine.estimateVO2max(40.0, "male", 90.0, 65.0, 5.0), 1e-3)

    @Test fun vo2maxWomen() =
        assertEquals(37.72, FitnessAgeEngine.estimateVO2max(40.0, "female", 80.0, 65.0, 5.0), 1e-3)

    @Test fun bmiHelper() =
        assertEquals(25.249, FitnessAgeEngine.bmi(80.0, 178.0), 1e-3)

    @Test fun referenceFitPersonEqualsChronoAge() {
        assertEquals(40.0, FitnessAgeEngine.fitnessAge(40.0, "male", 65.0, 5.0), 1e-9)
        assertEquals(55.0, FitnessAgeEngine.fitnessAge(55.0, "female", 65.0, 5.0), 1e-9)
    }

    @Test fun fitterIsYounger() =
        assertEquals(28.33, FitnessAgeEngine.fitnessAge(40.0, "male", 50.0, 10.0), 0.05)

    @Test fun unfitterIsOlder() =
        assertEquals(50.15, FitnessAgeEngine.fitnessAge(40.0, "male", 80.0, 2.0), 0.05)

    @Test fun clampHigh() = assertEquals(80.0, FitnessAgeEngine.fitnessAge(75.0, "male", 120.0, 0.0), 1e-9)
    @Test fun clampLow() = assertEquals(20.0, FitnessAgeEngine.fitnessAge(25.0, "male", 35.0, 15.0), 1e-9)

    @Test fun paiSedentary() = assertEquals(0.0, FitnessAgeEngine.physicalActivityIndex(0, 0.0, 0.0), 1e-9)
    @Test fun paiHigh() = assertEquals(15.0, FitnessAgeEngine.physicalActivityIndex(7, 75.0, 0.8), 1e-9)
    @Test fun paiModerate() = assertEquals(3.75, FitnessAgeEngine.physicalActivityIndex(3, 40.0, 0.3), 1e-9)

    @Test fun paiFromStrain() {
        assertEquals(0.0, FitnessAgeEngine.physicalActivityIndexFromStrain(0, 0.0), 1e-9)
        assertEquals(15.0, FitnessAgeEngine.physicalActivityIndexFromStrain(7, 90.0), 1e-9)
        assertEquals(3.75, FitnessAgeEngine.physicalActivityIndexFromStrain(3, 45.0), 1e-9)
        assertEquals(5.0, FitnessAgeEngine.physicalActivityIndexFromStrain(4, 60.0), 1e-9)
    }

    @Test fun computeReferencePerson() {
        val r = FitnessAgeEngine.compute(40.0, "male", 65.0, 5.0)
        assertNotNull(r)
        assertEquals(40.0, r!!.fitnessAge, 1e-9)
        assertEquals(0.0, r.deltaYears, 1e-9)
        assertNull(r.vo2max)
        assertFalse(r.lowerConfidence)
    }

    @Test fun computeWithWaistFillsVO2max() {
        val r = FitnessAgeEngine.compute(40.0, "male", 65.0, 5.0, waistCm = 90.0)
        assertEquals(46.275, r!!.vo2max!!, 1e-3)
    }

    @Test fun computeNonBinaryLowerConfidence() {
        val r = FitnessAgeEngine.compute(40.0, "nonbinary", 60.0, 6.0)
        assertTrue(r!!.lowerConfidence)
    }

    @Test fun computeNilNoRhr() = assertNull(FitnessAgeEngine.compute(40.0, "male", 0.0, 7.5))

    // Readiness checklist
    @Test fun readinessAllPresentIsReady() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 7, 7, true, true)
        assertEquals(FitnessAgeConfidence.READY, r.confidence)
        assertTrue(r.canCompute)
        assertTrue(r.items.all { it.status == FitnessReadinessStatus.SATISFIED })
        assertEquals(6, r.items.size)
    }

    @Test fun readinessMissingRhrIsNotReady() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 0, 7, true, true)
        assertEquals(FitnessAgeConfidence.NOT_READY, r.confidence)
        assertFalse(r.canCompute)
        assertEquals(FitnessReadinessStatus.MISSING, r.items.first { it.key == "rhr" }.status)
    }

    @Test fun readinessPartialIsEstimate() {
        val r = FitnessAgeEngine.assessReadiness(true, true, 5, 3, false, false)
        assertEquals(FitnessAgeConfidence.ESTIMATE, r.confidence)
        assertTrue(r.canCompute)
        val body = r.items.first { it.key == "bodyMetrics" }
        assertEquals(FitnessReadinessStatus.MISSING, body.status)
        assertEquals(FitnessReadinessRole.UNLOCKS_VO2MAX, body.role)
        assertFalse(body.required)
    }

    @Test fun readinessMissingAgeIsNotReady() {
        assertEquals(FitnessAgeConfidence.NOT_READY,
            FitnessAgeEngine.assessReadiness(false, true, 7, 7, true, true).confidence)
    }

    @Test fun readinessNoBodyMetricsStillReady() {
        assertEquals(FitnessAgeConfidence.READY,
            FitnessAgeEngine.assessReadiness(true, true, 7, 6, false, false).confidence)
    }
}
