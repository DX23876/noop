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
        assertEquals(listOf("training"), goal.contexts)
        val motivation = output.motivation!!
        assertTrue(motivation.badges.isNotEmpty())
        assertTrue(motivation.badges.all { it.title.isNotEmpty() && it.familyTitle.isNotEmpty() })
        assertTrue(output.motivationEnabled)
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

    @Test fun theGoalLinesKeepTheCoreWording() {
        val lines = CoreGoals.parseLines("""{"workout":["Counts toward Runs: 3/4"],"night":[]}""")!!
        assertEquals(listOf("Counts toward Runs: 3/4"), lines.workout)
        assertEquals(emptyList<String>(), lines.night)
        assertEquals(null, CoreGoals.parseLines("""{"error":"goalState"}"""))
        val preview = CoreGoals.parseLines(
            """{"workout":[],"night":[],"preview":[{"text":"This session reaches Workouts: 4/4","reaches":true}]}""")!!
        assertEquals(listOf(CoreGoals.Preview("This session reaches Workouts: 4/4", true)), preview.preview)
    }

    @Test fun theGoalNoticesKeepTheirMessagesAndState() {
        val notices = CoreGoals.parseNotices(
            """{"messages":[{"id":"goal-event-2026-10-28-0","title":"⭐ Daily steps reached","body":"","evening":false}],"state":"{\"day\":\"2026-10-28\"}"}""")!!
        assertEquals(listOf("goal-event-2026-10-28-0"), notices.messages.map { it.id })
        assertEquals("""{"day":"2026-10-28"}""", notices.state)
        assertEquals(null, CoreGoals.parseNotices("""{"error":"goalState"}"""))
    }
}
