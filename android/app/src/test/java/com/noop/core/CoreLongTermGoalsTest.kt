package com.noop.core

import org.junit.Assert.*
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Test

/** The long-term draft Swift emits (`CoreLongTermGoalsTests`): Kotlin must read the suggestion and send it back whole. */
class CoreLongTermGoalsTest {
    @Test fun theSwiftDraftKeepsItsSuggestionAndRoundTrips() {
        val json = javaClass.getResource("/goals/long-term-draft.json")!!.readText()
        val draft = CoreLongTermGoals.parseDraft(json)!!
        assertEquals("endurance.workoutsTotal", draft.state.template)
        assertEquals("sum", draft.shape)
        assertEquals("workouts", draft.weeklyMetricOfGoal)
        assertTrue(draft.state.target > 0)
        assertTrue(draft.state.endDate > 0)
        val sent = CoreLongTermGoals.encode(draft.state)
        assertEquals(draft.state.template, sent.getString("template"))
        assertEquals(draft.state.target, sent.getDouble("target"), 0.0)
    }

    @Test fun theSwiftLongTermPageKeepsItsHeroBandAndOptions() {
        val json = javaClass.getResource("/goals/long-term-page.json")!!.readText()
        val page = CoreLongTermGoals.parsePage(json)!!
        assertEquals(3, page.figures.size)
        assertEquals("milestones", page.band?.kind)
        assertTrue(page.band!!.points.isNotEmpty())
        assertTrue(page.statusText.isNotEmpty())
        assertTrue(page.insights.isNotEmpty())
        assertEquals(24, page.raise.size)
        assertEquals(page.raise.map { it.value }.sorted(), page.raise.map { it.value })
        assertFalse(page.reached)
    }
}
