package com.noop.core

import org.junit.Assert.*
import org.junit.Test

/** The goals answer Swift emits (`CoreGoalsTests`): Kotlin must read the goal, its pace and what counted unchanged. */
class CoreGoalsTest {
    @Test fun theSwiftGoalSnapshotKeepsItsPaceAndContributions() {
        val json = javaClass.getResource("/goals/snapshot.json")!!.readText()
        val output = CoreGoals.parse(json)!!
        val goal = output.period.single()
        assertEquals("workouts", goal.metric)
        assertEquals("week", goal.period)
        assertEquals("active", goal.status)
        assertEquals(3.0, goal.target, 0.0)
        assertEquals(1.0, goal.current, 0.0)
        assertEquals(7, goal.periodDays.size)
        assertEquals(goal.periodDays.size, goal.dayValues.size)
        assertEquals(1, goal.counted.size)
        assertEquals("Running", goal.counted.single().title)
        assertNotNull(goal.paceFraction)
        assertTrue(output.longTerm.isEmpty())
        assertTrue(output.periodLimit > 0)
        assertEquals(listOf("steps", "activeCalories", "sleep"), output.daily.map { it.slot })
        assertTrue(output.daily.all { it.value == null && it.values.isNotEmpty() })
        assertEquals(1, output.spotlight.weekTotal)
    }

    @Test fun anErrorAnswerReadsAsNoSnapshot() {
        assertNull(CoreGoals.parse("""{"error":"goalState"}"""))
        assertNull(CoreGoals.parse("null"))
    }
}
