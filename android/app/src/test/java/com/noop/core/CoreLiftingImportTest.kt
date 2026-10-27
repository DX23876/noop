package com.noop.core

import org.junit.Assert.*
import org.junit.Test

class CoreLiftingImportTest {
    @Test fun acknowledgedImportCarriesCounts() {
        val result = CoreLiftingImport.parse("""{"sessions":2,"skipped":3}""")
        assertEquals(2, result.sessions)
        assertEquals(3, result.skipped)
        assertNull(result.error)
    }

    @Test fun missingAcknowledgementNeverLooksLikeSuccess() {
        listOf(null, "", "{}", "null", "{\"sessions\":0}", "{\"sessions\":2,\"skipped\":-1}").forEach {
            assertNotNull(CoreLiftingImport.parse(it).error)
        }
        assertEquals("noWorkouts", CoreLiftingImport.parse("""{"error":"noWorkouts"}""").error)
    }
}
