package com.noop.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Swift supplies the immutable review and measurement kind; the host carries the wearer's selection. */
class CoreExerciseProviderTest {
    @Test fun theSwiftReviewReceiptKeepsItsIdentityAndDoesNotCarryCredentials() {
        val text = javaClass.getResource("/training/exercise-provider.json")!!.readText()
        val preview = CoreExerciseProvider.parse(JSONObject(text))
        assertEquals("synthetic-review", preview.token)
        assertEquals(listOf("exercisedb:body:bodyweight_reps", "exercisedb:loaded"), preview.exercises.map { it.id })
        assertEquals(listOf("bodyweight_reps", "weight_reps"), preview.exercises.map { it.mode })
        assertEquals(1, preview.attribution.size)
        assertTrue(preview.attribution.single().contains("AscendAPI"))
        assertTrue(preview.exercises.all { it.primary == "biceps" })
        assertFalse(text.contains("api_key"))
        assertFalse(text.contains("synthetic-key"))
    }
}
