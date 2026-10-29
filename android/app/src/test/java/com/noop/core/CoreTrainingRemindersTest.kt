package com.noop.core

import org.junit.Assert.*
import org.junit.Test

/** Swift supplies the session identity, activity and deadline; Kotlin must carry them unchanged. */
class CoreTrainingRemindersTest {
    @Test fun theSwiftReminderReceiptKeepsItsCanonicalSessionAndDeadline() {
        val json = javaClass.getResource("/training/rating-reminders.json")!!.readText()
        val result = CoreTrainingReminders.parse(json)
        assertEquals(1, result.size)
        val candidate = result.single()
        assertTrue(candidate.id.endsWith(candidate.sessionId))
        assertEquals("Strength Training", candidate.sport)
        assertEquals(6_000L, candidate.startTs)
        assertEquals(9_000L, candidate.endTs)
        assertEquals(10_800L, candidate.fireTs)
    }
}
