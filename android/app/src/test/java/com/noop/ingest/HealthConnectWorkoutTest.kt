package com.noop.ingest

import androidx.health.connect.client.records.ExerciseSessionRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A Health Connect session's sport and heart rate as the import stores them (testers, 2026-11). */
class HealthConnectWorkoutTest {
    @Test
    fun theTypeNamesTheSportAndATitleOnlyFillsIn() {
        assertEquals("Running", HealthConnectImporter.exerciseName(ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, "Morning Run"))
        assertEquals("Evening flow", HealthConnectImporter.exerciseName(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, " Evening flow "))
        assertEquals("Workout", HealthConnectImporter.exerciseName(ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT, null))
    }

    @Test
    fun oneSampleAMinuteStillGivesARunItsHeartRate() {
        val start = 1_000_000L
        val perMinute = (0 until 40).map { start + it * 60L to 120L + it }
        assertEquals(140 to 159, HealthConnectImporter.workoutHeartRate(perMinute, start, start + 40 * 60))
    }

    @Test
    fun aFewStraySamplesGiveNone() {
        val start = 1_000_000L
        val strays = (0 until 12).map { start + it * 5L to 150L }
        assertNull(HealthConnectImporter.workoutHeartRate(strays, start, start + 40 * 60))
        assertNull(HealthConnectImporter.workoutHeartRate(emptyList(), start, start + 60))
    }
}

/** A re-import replaces a session stored under its title, and nothing else. */
class HealthConnectLegacyTitleTest {
    private fun row(sport: String, start: Long, notes: String? = null) = com.noop.data.WorkoutRow(
        deviceId = HealthConnectImporter.HC_DEVICE, startTs = start, endTs = start + 2400, sport = sport,
        source = "health-connect", durationS = 2400.0, energyKcal = null, avgHr = null, maxHr = null, strain = null,
        distanceM = null, zonesJSON = null, notes = notes)

    @Test
    fun onlyTheTitleRowGoes() {
        val fresh = listOf(row("Running", 100, notes = "Morning Run"))
        val stored = listOf(row("Morning Run", 100, notes = "Morning Run"), row("Trail run", 100), row("Morning Run", 200))
        assertEquals(listOf(stored[0]), HealthConnectImporter.legacyTitleRows(stored, fresh))
    }
}
