package com.noop.analytics

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #510: a detected bout's own computed avgHR/calories/maxHR/strain must fill ONLY the fields a
 * colliding real (manual/imported) workout is missing — never override anything already present.
 * Regression for the report where manually-entered workouts silently showed no HR/calories even
 * though the detector had already computed a valid average for that exact window.
 */
class IntelligenceEngineWorkoutBackfillTest {

    private fun manualRow(avgHr: Int? = null, maxHr: Int? = null, energyKcal: Double? = null, strain: Double? = null) =
        WorkoutRow(
            deviceId = "my-whoop", startTs = 1_000L, endTs = 1_600L, sport = "Running", source = "manual",
            durationS = 600.0, energyKcal = energyKcal, avgHr = avgHr, maxHr = maxHr, strain = strain,
        )

    @Test
    fun fillsAllMissingFields() {
        val real = manualRow()
        val filled = IntelligenceEngine.backfillWorkoutFromDetectedBout(
            real, avgBpm = 150, peakHR = 170, caloriesKcal = 80.0, strain = 9.5,
        )
        assertEquals(150, filled.avgHr)
        assertEquals(170, filled.maxHr)
        assertEquals(80.0, filled.energyKcal)
        assertEquals(9.5, filled.strain)
        // The rest of the row is carried over untouched.
        assertEquals(real.startTs, filled.startTs)
        assertEquals(real.sport, filled.sport)
        assertEquals(real.source, filled.source)
    }

    @Test
    fun neverOverridesFieldsAlreadyPresent() {
        // The user typed an Avg HR and calories by hand; only maxHr/strain are missing.
        val real = manualRow(avgHr = 140, maxHr = null, energyKcal = 50.0, strain = null)
        val filled = IntelligenceEngine.backfillWorkoutFromDetectedBout(
            real, avgBpm = 150, peakHR = 170, caloriesKcal = 80.0, strain = 9.5,
        )
        assertEquals("a user-typed value must never be overwritten", 140, filled.avgHr)
        assertEquals("a user-typed value must never be overwritten", 50.0, filled.energyKcal)
        assertEquals("a missing field must still be filled", 170, filled.maxHr)
        assertEquals("a missing field must still be filled", 9.5, filled.strain)
    }

    @Test
    fun rowWithEverythingAlreadyPresentIsUnchanged() {
        val real = manualRow(avgHr = 140, maxHr = 160, energyKcal = 50.0, strain = 8.0)
        val filled = IntelligenceEngine.backfillWorkoutFromDetectedBout(
            real, avgBpm = 150, peakHR = 170, caloriesKcal = 80.0, strain = 9.5,
        )
        assertEquals("nothing to fill -> byte-identical row, so the caller can skip the write", real, filled)
    }
}
