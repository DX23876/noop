package com.noop.core

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** The exact Swift-prepared history is used as the parser oracle, including three kinds of missing day. */
class CoreTrainingHistoryTest {
    private fun document() = javaClass.getResource("/training/history.json")!!.readText()

    @Test fun lanesKeepTheirUnitsAndUnknownDays() {
        val h = CoreTrainingHistory.parse(document())!!
        assertEquals("threeMonths", h.span)
        assertEquals("day", h.resolution)
        assertEquals(92, h.cardio.size)
        val missing = h.cardio.single { it.start == "2026-10-24" }
        assertNull(missing.total)
        assertNull(missing.estimatedTotal)
        assertEquals(1, missing.unknownDays)
        val estimated = h.cardio.single { it.start == "2026-10-22" }
        assertNull(estimated.total)
        assertEquals(60.0, estimated.estimatedTotal!!, 0.0)
        assertEquals(1, estimated.estimatedDays)
        assertTrue(h.strength.any { it.total != null })
        assertTrue(h.strength.any { it.band != null })
        assertTrue(h.session.any { it.total != null })
        assertTrue(h.session.all { it.band == null })
        val firstUnrated = h.session.single { it.start == "2026-08-29" }
        assertEquals(1, firstUnrated.unknownDays)
        assertEquals(1, firstUnrated.possible)
        assertEquals(0, firstUnrated.unrecordedDays)
        assertTrue(h.session.sumOf { it.possible ?: 0 } > h.session.sumOf { it.measured ?: 0 })
    }

    @Test fun adaptationsKeepPeriodGapsAndImportedWatchReadings() {
        val h = CoreTrainingHistory.parse(document())!!
        val lift = h.lifts.single()
        assertEquals("bench", lift.id)
        assertEquals("Bench press", lift.title)
        assertEquals(92, lift.values.size)
        assertTrue(lift.values.any { it.value == null })
        assertTrue(lift.values.any { it.value != null })
        assertEquals(listOf(42.0, 43.0), h.vo2.mapNotNull { it.value })
        assertEquals(listOf(44.0), h.vo2Apple.mapNotNull { it.value })
        assertEquals("bench", h.choices.single().id)
    }

    @Test fun noMeasurementNeverBecomesZeroAndCorruptReadsAreUnavailable() {
        val o = JSONObject(document())
        o.getJSONArray("strength").getJSONObject(0).put("total", JSONObject.NULL)
        assertNull(CoreTrainingHistory.parse(o.toString())!!.strength.first().total)
        listOf("{}", "null", "bad", "{\"error\":\"unavailable\"}").forEach { assertNull(CoreTrainingHistory.parse(it)) }
    }

    @Test fun yearHeatmapKeepsCoreCalendarAndMinutes() {
        val h = CoreTrainingReports.parseStrength(javaClass.getResource("/training/strength.json")!!.readText())!!
        assertTrue(h.activity.size in 364..371)
        assertEquals(5, h.activity.count { it.minutes > 0 })
        assertEquals(300.0, h.activity.sumOf { it.minutes }, 0.0)
        assertTrue(h.activity.zipWithNext().all { (a,b) -> a.day < b.day })
    }
}
