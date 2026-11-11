package com.noop.ui.forge

import org.junit.Assert.assertEquals
import org.junit.Test

/** The hint order and the day-scoped dismissals, as Apple's `ForgeTodayHint`. */
class TodayHintsTest {
    private fun notice(key: String, tone: String, at: Long) =
        TodayNotices.Notice(key, at, "load", tone, key, "", null, null)

    @Test fun warningLeadsThenCareBeforeNewsThenWeighIn() {
        val hints = TodayHints.candidates(
            listOf(notice("news", "positive", 30), notice("care", "caution", 10), notice("alert", "critical", 5),
                   notice("care2", "caution", 20)),
            weighIn = true, weighTitle = "w", weighDetail = "d", dismissed = emptySet())
        assertEquals(listOf("alert", "care2", "care", "news", "hint.weighIn"), hints.map { it.id })
    }

    @Test fun dismissedHintsStayAwayForTheDayOnly() {
        val raw = TodayHints.dismissing("care", "2026-11-11", "2026-11-10|old")
        assertEquals("2026-11-11|care", raw)
        assertEquals(setOf("care"), TodayHints.dismissed(raw, "2026-11-11"))
        assertEquals(emptySet<String>(), TodayHints.dismissed(raw, "2026-11-12"))
        val hints = TodayHints.candidates(listOf(notice("care", "caution", 1)), false, "w", "d", TodayHints.dismissed(raw, "2026-11-11"))
        assertEquals(emptyList<String>(), hints.map { it.id })
    }

    @Test fun momentumKindsMapToApplesTopics() {
        assertEquals("bodySignals", TodayNotices.topic("hrvTrend"))
        assertEquals("goals", TodayNotices.topic("streak"))
        assertEquals(null, TodayNotices.topic("recoveryRead"))
        assertEquals(4.0, TodayNotices.severity("critical"), 0.0)
    }

    @Test fun aPlanWaitingAndTheCoachNoteComeRightAfterTheWarning() {
        val note = com.noop.core.CoreCoach.Note("n1", 10, "brief", null, "Morning", "", null, null, emptyList(), emptyList(), emptyList())
        val hints = TodayHints.candidates(listOf(notice("care", "caution", 1), notice("alert", "critical", 2)), false, "w", "d",
                                          emptySet(), proposal = true, proposalTitle = "p", coach = note)
        assertEquals(listOf("alert", "hint.proposal", "n1", "care"), hints.map { it.id })
    }
}
