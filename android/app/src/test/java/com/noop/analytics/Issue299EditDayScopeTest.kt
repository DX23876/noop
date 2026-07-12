package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * #299: "sleep always 85%". A single userEdited night / hand-logged nap was folded into EVERY night in the
 * recompute window because the edit set was built window-wide — so one edit's total (e.g. 453 min) was
 * substituted onto every night, including nights that detected no sleep at all. The fix scopes edits to the
 * day their night ENDS on. Pins [IntelligenceEngine.editedRowsForDay] (byte-identical twin of Swift
 * `IntelligenceEngine.editedRowsForDay`); the full analyzeRecent fold needs a live Room repo the JVM harness
 * can't build, so — matching the existing sleep-analytics test pattern — this pins the pure day-scoping.
 */
class Issue299EditDayScopeTest {

    private val tz = 0L
    private val base = 1_783_620_000L    // 18:00 UTC — so base and base+1h share a day, base+24h is the next

    private fun edit(startTs: Long, endTs: Long) =
        SleepSession(deviceId = "my-whoop", startTs = startTs, endTs = endTs, userEdited = true)

    @Test
    fun `an edit folds only into the day its night ends on, not every night`() {
        val dayX = AnalyticsEngine.dayString(base, tz)
        val dayNext = AnalyticsEngine.dayString(base + 86_400L, tz)

        val e1 = edit(base - 6 * 3600, base)                        // ends dayX
        val e2 = edit(base - 5 * 3600, base + 3600)                 // ends dayX, an hour later
        val e3 = edit(base + 86_400 - 6 * 3600, base + 86_400)      // ends dayNext
        val all = listOf(e1, e2, e3)

        assertEquals("dayX gets only its own edits", listOf(e1, e2),
            IntelligenceEngine.editedRowsForDay(all, dayX, tz))
        assertEquals("dayNext gets only its own edit (not the whole window)", listOf(e3),
            IntelligenceEngine.editedRowsForDay(all, dayNext, tz))
    }

    @Test
    fun `a day with no edit of its own gets none — the matched=0 night stays null, not 453`() {
        val e = edit(base - 6 * 3600, base)                         // a single edit on dayX
        val emptyDay = AnalyticsEngine.dayString(base + 5 * 86_400L, tz)   // 5 days on, no edit
        assertEquals(emptyList<SleepSession>(),
            IntelligenceEngine.editedRowsForDay(listOf(e), emptyDay, tz))
    }
}
