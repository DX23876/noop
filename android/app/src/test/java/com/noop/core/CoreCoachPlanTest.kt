package com.noop.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The coach's history and plan book arrive as the core words them (`CoreCoach.swift`). */
class CoreCoachPlanTest {
    @Test
    fun planRowsAndChoicesParse() {
        val plan = CoreCoach.parsePlan(JSONObject("""
            {"pending":[{"id":"a","summary":"Run (easy)","rationale":"Fresh legs","day":"2026-10-29","dayLabel":"Tomorrow",
              "status":"proposed","swappedFrom":null,"statusLine":"proposed","feedback":null,"feedbackLabel":null}],
             "agreed":[],"recent":[{"id":"b","summary":"Ride (hard)","rationale":"","day":"2026-10-26","dayLabel":"Mon 26 Oct",
              "status":"completed","statusLine":"completed — Helpful","feedback":"helpful","feedbackLabel":"Helpful"}],
             "empty":false,"skipReasons":[{"id":"pain","label":"Pain"}],"feedbacks":[{"id":"helpful","label":"Helpful"}]}
        """.trimIndent()))!!
        assertEquals("Tomorrow", plan.pending.single().dayLabel)
        assertNull(plan.pending.single().swappedFrom)
        assertEquals("Helpful", plan.recent.single().feedbackLabel)
        assertEquals("pain" to "Pain", plan.skipReasons.single())
        assertTrue(plan.agreed.isEmpty())
    }

    @Test
    fun conversationsParseWithMilliseconds() {
        val rows = CoreCoach.parseConversations(JSONObject("""
            {"conversations":[{"id":"x","title":"Sleep","preview":"Hi","updatedAt":1761650000.5,"pinned":true,
              "archived":false,"active":true,"searchText":"Sleep\nHi"}]}
        """.trimIndent()))!!
        assertEquals(1_761_650_000_500L, rows.single().updatedAt)
        assertTrue(rows.single().pinned && rows.single().active)
    }
}
