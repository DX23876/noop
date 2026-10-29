package com.noop.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** The producer is Swift; these fixtures pin its job and reviewed-plan documents. */
class CoreHevyImportTest {
    private fun fixture(name: String) = JSONObject(javaClass.getResource("/training/$name.json")!!.readText())
    @Test fun theJobReceiptReportsStoredUpdatedRemovedAndSkippedSeparately() {
        val s = CoreHevyImport.parse(fixture("hevy-status"))
        assertEquals("completed", s.state)
        assertEquals("synthetic-job", s.id)
        assertEquals(21, s.stored)
        assertEquals(2, s.updated)
        assertEquals(1, s.deleted)
        assertEquals(3, s.skipped)
        assertNull(s.error)
    }
    @Test fun theReviewCarriesStableChoicesAndAnOpaqueToken() {
        val p = CoreHevyImport.parsePreview(fixture("hevy-routines"))
        assertEquals("synthetic-preview", p.token)
        assertEquals(setOf("Synthetic push", "Synthetic custom"), p.routines.map { it.title }.toSet())
        assertEquals(2, p.routines.map { it.id }.distinct().size)
        assertTrue(p.routines.all { it.exercises.isNotEmpty() })
    }
    @Test fun anUnknownOrUnidentifiedRunningJobCannotLookSuccessful() {
        assertEquals("decode", CoreHevyImport.parse(JSONObject("""{"state":"unknown"}""")).error)
        assertEquals("decode", CoreHevyImport.parse(JSONObject("""{"state":"running"}""")).error)
    }
}
