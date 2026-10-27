package com.noop.core

import org.junit.Assert.*
import org.junit.Test

class CoreLiftingImportTest {
    @Test fun acknowledgedImportCarriesCounts() {
        val result = CoreLiftingImport.parse(javaClass.getResource("/training/lifting-import.json")!!.readText())
        assertEquals(1, result.sessions)
        assertEquals(0, result.skipped)
        assertNull(result.error)
        val row = result.workouts.single()
        assertEquals("lifting", row.source)
        assertEquals(1_780_329_600L, row.startTs)
        assertEquals(3600.0, row.durationS!!, 0.0)
        assertNull(row.avgHr)
        assertNull(row.strain)
        assertTrue(row.notes!!.contains("640 kg"))
    }

    @Test fun missingAcknowledgementNeverLooksLikeSuccess() {
        listOf(null, "", "{}", "null", "{\"sessions\":0}", "{\"sessions\":2,\"skipped\":-1}").forEach {
            assertNotNull(CoreLiftingImport.parse(it).error)
        }
        assertEquals("noWorkouts", CoreLiftingImport.parse("""{"error":"noWorkouts"}""").error)
    }
}
