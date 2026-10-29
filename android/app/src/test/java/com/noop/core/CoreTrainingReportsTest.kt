package com.noop.core

import com.noop.ui.UnitSystem
import com.noop.ui.forge.cardioRate
import com.noop.ui.forge.reportPace
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

/** Fixtures are emitted and their field/type contract checked by the Swift CoreTrainingReportsTests. */
class CoreTrainingReportsTest {
    private fun fixture(name: String): String = javaClass.getResource("/training/$name.json")!!.readText()

    @Test fun strengthKeepsWarmupsRecordsAndCoverage() {
        val r = CoreTrainingReports.parseStrength(fixture("strength"))!!
        assertEquals(1, r.workingSets)
        assertEquals(1, r.volumeSets)
        assertEquals(5, r.overview.volumeSets)
        assertEquals(5, r.overview.durationSessions)
        assertEquals(5, r.overview.workingSets)
        assertEquals(5, r.overview.ratedSets)
        assertEquals(-4, r.selection.minWeekOffset)
        assertEquals("bench", r.exercise.selectedId)
        assertEquals(5, r.exercise.choices.single().sessions)
        assertEquals(80.0, r.exercise.heaviestSet!!.value, 0.0)
        assertEquals(640.0, r.exercise.bestSessionVolume!!.value, 0.0)
        assertEquals("bench-0", r.exercise.repRecords.getValue("sevenToTwelve").workoutId)
        assertEquals(5, r.exercise.trend!!.pointCount)
        assertFalse(r.exercise.trend!!.unclear)
        val s = r.recentSessions.first()
        assertEquals("hevy_csv", s.source)
        assertEquals(listOf("warmup", "normal"), s.exercises.single().sets.map { it.type })
        assertEquals(listOf(false, true), s.exercises.single().sets.map { it.countsAsWork })
        assertNull(s.exercises.single().sets.first().rpe)
        assertEquals(8.0, s.exercises.single().sets.last().rpe!!, 0.0)
        assertTrue(r.genericSessions.isEmpty())
        assertNull(r.lane.percent)
        assertTrue(r.ratios.all { it.strength == null })
        assertEquals(1, r.lane.measuredCount)
        assertEquals(1, r.lane.possibleCount)
    }

    @Test fun theManualEditorKeepsItsStoredScaleAndStableWorkoutId() {
        val r = CoreTrainingReports.parseStrength(fixture("strength-details"))!!
        val entry = r.genericSessions.single()
        assertEquals(r.recentSessions.single().id, entry.manualWorkoutId)
        assertEquals(1_800.0, r.recentSessions.single().durationS!!, 0.0)
        val draft = entry.drafts.single()
        assertEquals("Bench press", draft.title)
        assertEquals(5, draft.workSets)
        assertEquals("chest", draft.muscle)
        assertFalse("Stored ratings reopen on the RPE scale", draft.usesRIR)
        assertEquals(8.5, draft.effort.replace(',', '.').toDouble(), 0.0)
        assertEquals(5, draft.json().getInt("workSets"))
        assertFalse(draft.json().getBoolean("usesRIR"))
    }

    @Test fun cardioUsesSpeedForCyclingAndLeavesUnmeasuredZonesAbsent() {
        val r = CoreTrainingReports.parseCardio(fixture("cardio"))!!
        assertEquals("Cycling", r.progress.selectedSport)
        assertEquals("speed", r.progress.metric)
        assertEquals("cycling", r.progress.modality)
        assertEquals(listOf(22.0, 24.0, 26.0, 28.0, 30.0), r.progress.pace.map { it.value })
        assertEquals(2.0, r.progress.paceTrend!!.slopePerWeek, 0.0)
        assertEquals(30_000.0, r.progress.farthest!!.value, 0.0)
        assertEquals(3_600.0, r.progress.longest!!.value, 0.0)
        assertEquals(120.0, r.progress.paceBests.getValue("medium").value, 0.0)
        assertEquals(5, r.sessions.size)
        assertEquals("endurance", r.sessions.first().family)
        assertTrue(r.lane!!.isLowerBound)
        assertNull(r.zones)
        assertEquals(130.0, r.averageHr!!, 0.0)
    }

    @Test fun zoneCoverageAndMinuteAveragesSurviveTheBoundary() {
        val r = CoreTrainingReports.parseCardio(fixture("cardio-zones"))!!
        val zones = r.zones!!
        assertEquals(listOf(10.0, 15.0, 5.0, 0.0, 0.0), zones.minutes)
        assertEquals(1, zones.sessionsRead)
        assertEquals(2, zones.sessionsPossible)
        assertTrue(zones.usedMinuteBuckets)
    }

    @Test fun explicitNullPointsStayGapsAndFailuresStayUnavailable() {
        val json = JSONObject(fixture("strength"))
        json.getJSONObject("exercise").getJSONArray("points").getJSONObject(1).put("value", JSONObject.NULL)
        assertNull(CoreTrainingReports.parseStrength(json.toString())!!.exercise.points[1].value)
        listOf("null", "{}", "not json", "{\"error\":\"storeUnavailable\"}").forEach {
            assertNull(CoreTrainingReports.parseStrength(it))
            assertNull(CoreTrainingReports.parseCardio(it))
        }
    }

    @Test fun sportUnitsDoNotTurnSwimPaceOrSpeedIntoRunningPace() {
        val original = Locale.getDefault()
        try {
            Locale.setDefault(Locale.US)
            assertEquals("2:00 /100 m", reportPace(1_200.0, "swimming", UnitSystem.IMPERIAL))
            assertEquals("2:00 /100 m", reportPace(1_200.0, "swimming", UnitSystem.METRIC))
            assertEquals("5:00 /km", reportPace(300.0, "foot", UnitSystem.METRIC))
            assertEquals("8:03 /mi", reportPace(300.0, "foot", UnitSystem.IMPERIAL))
            assertEquals("1.2 mph", cardioRate(2.0, "speed", "cycling", UnitSystem.IMPERIAL))
            assertEquals("2.0 s/100 m", cardioRate(20.0, "pace", "swimming", UnitSystem.IMPERIAL))
        } finally { Locale.setDefault(original) }
    }
}
