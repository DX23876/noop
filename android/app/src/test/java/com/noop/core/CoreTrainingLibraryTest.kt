package com.noop.core

import com.noop.ui.forge.ExerciseLibraryFilters
import com.noop.ui.forge.TrainingSetInput
import com.noop.ui.UnitSystem
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Documents are emitted by Swift CoreTrainingLibraryTests, including the imported/native record merge. */
class CoreTrainingLibraryTest {
    private fun fixture(name: String): String = javaClass.getResource("/training/$name.json")!!.readText()

    @Test fun catalogAndDetailKeepTheirCoreIdentityAndProvenance() {
        val catalog = CoreTrainingLibrary.parseCatalog(fixture("library"))!!
        val row = catalog.exercises.single()
        val detail = CoreTrainingLibrary.parseDetail(fixture("exercise-detail"))!!
        assertEquals(row.id, detail.exercise.id)
        assertTrue(row.id.startsWith("user:"))
        assertEquals("Bench press", row.title)
        assertEquals("user", row.source)
        assertEquals("chest", row.region)
        assertEquals(listOf("chest"), row.primary)
        assertEquals(listOf("barbell"), row.equipment)
        assertTrue(row.matchingMuscles.contains("triceps"))
        assertEquals(listOf("Keep a stable setup."), detail.instructions)
        assertEquals(2, detail.records.sessions)
        assertEquals(85.0, detail.records.heaviestKg!!, 0.0)
        assertNotNull(detail.records.estimatedOneRepMaxKg)
        assertEquals(listOf(true, false), detail.recent.map { it.isNative })
        assertEquals(listOf(1, 1), detail.recent.map { it.workingSets })
        assertFalse(detail.hasDraft)
    }

    @Test fun filtersSearchLocalizedMusclesEquipmentAliasesAndReviewedSecondaries() {
        val row = CoreTrainingLibrary.parseCatalog(fixture("library"))!!.exercises.single()
        val muscles = mapOf("chest" to "Brust", "triceps" to "Trizeps")
        val equipment = mapOf("barbell" to "Langhantel")
        for (query in listOf(" BENCH ", "Brust", "Trizeps", "Langhantel")) {
            assertEquals(listOf(row.id), ExerciseLibraryFilters(query).apply(listOf(row), emptySet(), muscles, equipment).map { it.id })
        }
        assertEquals(1, ExerciseLibraryFilters(region = "chest", muscle = "triceps", equipment = "barbell", mode = "weight_reps")
            .apply(listOf(row), emptySet(), muscles, equipment).size)
        assertTrue(ExerciseLibraryFilters(mode = "duration").apply(listOf(row), emptySet(), muscles, equipment).isEmpty())
        assertTrue(ExerciseLibraryFilters(favoritesOnly = true).apply(listOf(row), emptySet(), muscles, equipment).isEmpty())
        assertEquals(1, ExerciseLibraryFilters(favoritesOnly = true).apply(listOf(row), setOf(row.id), muscles, equipment).size)
        val alias = row.copy(aliases = listOf("Développé couché"))
        assertEquals(1, ExerciseLibraryFilters("developpe").apply(listOf(alias), emptySet(), muscles, equipment).size)
    }

    @Test fun browsingDoesNotSilentlyStopAtTheOld150RowLimit() {
        val base = CoreTrainingLibrary.parseCatalog(fixture("library"))!!.exercises.single()
        val rows = (0..220).map { base.copy(id = "exercise-$it", title = "Exercise $it") }
        assertEquals(221, ExerciseLibraryFilters().apply(rows, emptySet(), emptyMap(), emptyMap()).size)
        assertEquals(listOf("exercise-220"), ExerciseLibraryFilters(favoritesOnly = true)
            .apply(rows, setOf("exercise-220"), emptyMap(), emptyMap()).map { it.id })
    }

    @Test fun everyCoreMeasurementKindHasTheRightInputColumns() {
        val catalog = CoreTrainingLibrary.parseCatalog(fixture("library"))!!
        assertEquals(setOf("weight_reps", "bodyweight_reps", "weighted_bodyweight", "assisted_bodyweight", "repetitions", "duration", "distance_duration", "weight_duration", "distance_weight"), catalog.modes.toSet())
        assertEquals(listOf(TrainingSetInput.Weight, TrainingSetInput.Seconds), TrainingSetInput.columns("weight_duration", false))
        assertEquals(listOf(TrainingSetInput.Weight, TrainingSetInput.Distance), TrainingSetInput.columns("distance_weight", false))
        assertEquals(listOf(TrainingSetInput.Seconds), TrainingSetInput.columns("duration", false))
        assertEquals(listOf(TrainingSetInput.Distance, TrainingSetInput.Seconds), TrainingSetInput.columns("distance_duration", false))
        for (mode in listOf("bodyweight_reps", "repetitions")) {
            assertEquals(listOf(TrainingSetInput.Reps), TrainingSetInput.columns(mode, false))
            assertEquals(listOf(TrainingSetInput.Left, TrainingSetInput.Right), TrainingSetInput.columns(mode, true))
        }
        for (mode in listOf("weight_reps", "weighted_bodyweight", "assisted_bodyweight")) {
            assertEquals(listOf(TrainingSetInput.Weight, TrainingSetInput.Reps), TrainingSetInput.columns(mode, false))
            assertEquals(listOf(TrainingSetInput.Weight, TrainingSetInput.Left, TrainingSetInput.Right), TrainingSetInput.columns(mode, true))
        }
        assertTrue(TrainingSetInput.columns("unknown", false).isEmpty())
    }

    @Test fun draftKeepsDurationDistanceAndEachSideWithoutFallingBackToGenericReps() {
        val draft = CoreTraining.parseDraft(fixture("library-draft"))!!
        val timed = draft.exercises.first().sets.first()
        assertEquals(75, timed.durationS)
        assertEquals(250.5, timed.distanceM!!, 0.0)
        assertTrue(timed.done)
        val sides = draft.exercises.last().sets.first()
        assertEquals(8, sides.leftReps)
        assertEquals(6, sides.rightReps)
        assertNull(sides.reps)
    }

    @Test fun draftCarriesEachSetsEffortRating() {
        val json = """{"id":"d","title":"T","startedAt":1,"exercises":[{"id":"e","exerciseId":"x","restSeconds":90,"sets":[
            {"id":"a","index":0,"phase":"working","isCompleted":true,"effort":{"scale":"rir","value":1.5}},
            {"id":"b","index":1,"phase":"working","isCompleted":false}]}]}"""
        val sets = CoreTraining.parseDraft(json)!!.exercises.single().sets
        assertEquals("rir", sets[0].effortScale)
        assertEquals(1.5, sets[0].effortValue!!, 0.0)
        assertNull(sets[1].effortScale)
        assertNull(sets[1].effortValue)
    }

    @Test fun inputUnitConversionsRoundTripAndUntouchedReadingsStayExact() {
        for (units in UnitSystem.entries) {
            assertEquals(80.123456789, TrainingSetInput.massForStore(TrainingSetInput.massForInput(80.123456789, units), units), 1e-10)
            assertEquals(250.5, TrainingSetInput.distanceForStore(TrainingSetInput.distanceForInput(250.5, units), units), 1e-9)
        }
        val original = 80.123456789
        assertEquals(original, TrainingSetInput.editedMeasurement(original, "176.641897", "176.641897") {
            error("a rounded display value must not rewrite an untouched measurement")
        }!!, 0.0)
        assertNull(TrainingSetInput.editedMeasurement(original, "80", "") { it })
    }

    @Test fun aSavedWorkoutNamedErrorIsStillASuccessfulAcknowledgement() {
        assertTrue(CoreTraining.parseFinished("""{"id":"saved-workout","endedAt":100,"title":"error"}"""))
        assertFalse(CoreTraining.parseFinished("null"))
        assertFalse(CoreTraining.parseFinished("{}"))
        assertFalse(CoreTraining.parseFinished("""{"error":"notSaved"}"""))
    }

    @Test fun anUnperformedExerciseDoesNotInventRecordsAndUnavailableRepliesStayUnavailable() {
        val document = JSONObject(fixture("exercise-detail"))
            .put("records", JSONObject().put("sessions", 0)).put("recent", JSONArray())
        val detail = CoreTrainingLibrary.parseDetail(document.toString())!!
        assertEquals(0, detail.records.sessions)
        assertNull(detail.records.heaviestKg)
        assertNull(detail.records.estimatedOneRepMaxKg)
        assertNull(detail.records.lastPerformedTs)
        assertTrue(detail.recent.isEmpty())
        for (json in listOf("null", "{}", "not json", "{\"error\":\"libraryUnavailable\"}")) {
            assertNull(CoreTrainingLibrary.parseCatalog(json))
            assertNull(CoreTrainingLibrary.parseDetail(json))
        }
    }
}
