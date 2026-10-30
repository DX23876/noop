package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The core's sleep blocks arrive as Room's `SleepSession` rows (`read.sleepSessions`). */
class CoreSleepSessionsTest {
    @Test
    fun blocksParseWithTheirDeviceOrTheFallback() {
        val rows = CoreSleepSessions.parse("""
            {"sessions":[{"startTs":100,"endTs":200,"efficiency":0.9,"restingHr":50,"avgHrv":60.5,"stagesJSON":"[]",
              "userEdited":true,"startTsAdjusted":110,"stagingSparse":false,"deviceId":"whoop-a-noop"},
             {"startTs":300,"endTs":360,"userEdited":false}]}
        """.trimIndent(), "my-whoop")!!
        assertEquals("whoop-a-noop", rows[0].deviceId)
        assertEquals(110L, rows[0].startTsAdjusted)
        assertTrue(rows[0].userEdited)
        assertEquals("my-whoop", rows[1].deviceId)
        assertNull(rows[1].efficiency)
        assertNull(rows[1].stagingSparse)
    }

    @Test
    fun unexpectedShapeReadsRoom() {
        assertNull(CoreSleepSessions.parse("""{"error":"noStore"}""", "my-whoop"))
    }
}
