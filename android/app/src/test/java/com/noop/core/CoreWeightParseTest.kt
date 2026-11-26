package com.noop.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The weight page reads the core's snapshot field for field (`CoreWeight.swift`, dates as unix seconds). */
class CoreWeightParseTest {
    private val json = """
        {"events":[{"createdAt":1795000000,"day":"2026-12-10","id":"e1","name":"Wedding"}],"goalSource":"goal",
         "settings":{"basis":"tenDayLow","hiddenCards":["reports"],"rateMode":"wish","rateWindowDays":56},
         "snapshot":{"changes":[{"days":7,"kg":-0.6},{"kg":-4.1}],
           "events":[{"daysAway":14,"event":{"createdAt":1795000000,"day":"2026-12-10","id":"e1","name":"Wedding"},
                      "phase":"upcoming","predictedKg":94.9}],
           "forecast":{"basis":"tenDayLow","rateKgPerWeek":-0.5,"rateMode":"wish","startDate":1795600000,"startKg":95.8,
                       "state":"arriving","targetDate":1800000000},
           "goal":{"baseline":100,"createdAt":1790000000,"storedMilestones":[],"target":90},
           "latest":{"date":1795600000,"kg":95.8},
           "log":[{"day":"2026-11-26","milestoneKg":96,"reading":{"date":1795600000,"id":"w1","kg":95.8,"note":"after run","source":"noop"},
                   "trendKg":96.1,"weeklyRateKg":-0.6}],
           "milestones":{"next":94,"progress":0.39,"reachedCount":2,"route":[{"kg":98,"reachedDay":"2026-11-01"},{"kg":94}],"toNextKg":2.1},
           "months":[{"count":3,"enough":false,"key":"2026-10","period":"month","readings":[],"start":1790000000,"trend":[]}],
           "rates":{"currentKgPerWeek":-0.45,"wishIsSteep":false,"wishKgPerWeek":-0.5,"wishSource":"dietPlan"},
           "readingCount":40,"readings":[],"trend":[],"trendKg":96.1,"trendSettled":true,"years":[]}}
    """.trimIndent()

    @Test fun readsEveryPart() {
        val page = CoreWeight.parse(json)!!
        assertEquals("goal", page.goalSource)
        assertEquals("tenDayLow", page.settings.basis)
        assertEquals(56, page.settings.rateWindowDays)
        assertTrue(!page.settings.shows("reports"))
        assertEquals(listOf("Wedding"), page.events.map { it.name })
        val s = page.snapshot!!
        assertEquals(listOf(7, null), s.changes.map { it.days })
        assertEquals("arriving", s.forecast.state)
        assertEquals(1800000000L, s.forecast.targetAt)
        assertEquals(94.9, s.events.single().predictedKg!!, 1e-9)
        assertEquals("after run", s.log.single().reading.note)
        assertEquals(96.0, s.log.single().milestoneKg!!, 1e-9)
        assertNull("an unreached milestone has no day", s.milestones!!.route[1].reachedDay)
        assertEquals("dietPlan", s.rates.wishSource)
        assertNull(s.rates.overall)
        assertNull(s.week)
        assertEquals(false, s.months.single().enough)
        assertNotNull(s.goal)
    }

    @Test fun settingsRoundTripTheCoresKeys() {
        val json = CoreWeight.Settings(milestoneStepKg = 5.0, hiddenCards = listOf("week")).json()
        val back = CoreWeight.parse("""{"settings":$json,"events":[]}""")!!.settings
        assertEquals(5.0, back.milestoneStepKg!!, 1e-9)
        assertEquals(listOf("week"), back.hiddenCards)
    }
}
