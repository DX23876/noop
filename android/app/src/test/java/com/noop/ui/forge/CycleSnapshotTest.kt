package com.noop.ui.forge

import com.noop.analytics.CyclePhaseEngine
import com.noop.core.CoreCycle
import com.noop.data.CycleLogStore
import com.noop.data.DailyMetric
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/** The cycle page's snapshot and day log, as iOS `ForgeCycleSnapshot.make` and `CycleLog`. */
class CycleSnapshotTest {
    private val today = LocalDate.parse("2026-11-20")
    private fun result(shift: String?, phase: CyclePhaseEngine.Phase = CyclePhaseEngine.Phase.LUTEAL) = CyclePhaseEngine.Result(
        phase, CyclePhaseEngine.Confidence.SOLID, null, null, 29, null, listOfNotNull(shift?.let { CyclePhaseEngine.ShiftMarker(it) }), "")

    @Test fun theLoggedPeriodWinsThenThisCyclesRisePlacesToday() {
        val period = CycleSnapshot.make(result(null), listOf("2026-11-18"), emptyMap(), emptyList(), today)
        assertEquals(3, period.cycleDay); assertEquals(CyclePhase.Period, period.phase)
        // Started on the 1st, rise on the 15th (cycle day 15): day 20 is past the shift, so luteal.
        val luteal = CycleSnapshot.make(result("2026-11-15"), listOf("2026-11-01"), emptyMap(), emptyList(), today)
        assertEquals(20, luteal.cycleDay); assertEquals(15, luteal.shiftDay); assertEquals(CyclePhase.Luteal, luteal.phase)
        assertEquals(CyclePhase.Shift, luteal.phase(15)); assertEquals(CyclePhase.Follicular, luteal.phase(10))
        assertEquals(CyclePhase.Period, luteal.phase(3))
    }

    @Test fun flowLoggedLongerThanFiveDaysStretchesThePeriod() {
        val log = (0 until 7).associate { "2026-11-${String.format("%02d", 14 + it)}" to CycleLogStore.Day(flow = 2) }
        val snap = CycleSnapshot.make(null, listOf("2026-11-14"), log, emptyList(), today)
        assertEquals(7, snap.periodLength); assertEquals(CyclePhase.Period, snap.phase)
        assertTrue("2026-11-20" in snap.periodDays)
    }

    @Test fun lutealNightsAreComparedWithTheFirstHalf() {
        val start = LocalDate.parse("2026-10-30")
        val days = (0 until 22).map { i ->
            val warm = i + 1 > 17
            DailyMetric("my-whoop", start.plusDays(i.toLong()).toString(), skinTempDevC = if (warm) 0.4 else 0.0,
                        restingHr = if (warm) 58 else 55, recovery = if (warm) 60.0 else 70.0)
        }
        val snap = CycleSnapshot.make(result("2026-11-14"), listOf(start.toString()), emptyMap(), days, today)
        assertEquals(CyclePhase.Luteal, snap.phase)
        assertEquals(0.4, snap.compare!!.tempDelta!!, 1e-9)
        assertEquals(3.0, snap.compare!!.rhrDelta!!, 1e-9)
        assertEquals(22, snap.temps.size)
    }

    @Test fun pastRisesAndTheTestDayGoToTheFertileEstimate() {
        var asked: List<Any?>? = null
        val starts = listOf("2026-08-08", "2026-09-05", "2026-10-03", "2026-10-31", "2026-11-12")
        val shifts = listOf("2026-08-22", "2026-09-19", "2026-10-17", "2026-11-10")
        val r = CyclePhaseEngine.Result(CyclePhaseEngine.Phase.FOLLICULAR, CyclePhaseEngine.Confidence.SOLID, null, null, 28, null,
                                        shifts.map { CyclePhaseEngine.ShiftMarker(it) }, "")
        val log = mapOf("2026-11-19" to CycleLogStore.Day(ovulationTest = true))
        CycleSnapshot.make(r, starts, log, emptyList(), today) { past, rise, test, day -> asked = listOf(past, rise, test, day); null }
        // Newest cycle first and dropped (the current one); each past rise as a cycle day.
        assertEquals(listOf(listOf(11, 15, 15, 15), null, 8, 9), asked)
    }

    @Test fun theDayLogReadsBackAndClearingDeletesRows() = runBlocking {
        val rows = mutableListOf<com.noop.data.MetricSeriesRow>()
        val store = CycleLogStore({ rows.removeAll { r -> it.any { it.day == r.day && it.key == r.key } }; rows += it },
            { _, key, from, to -> rows.filter { it.key == key && it.day in from..to } },
            { _, day, key -> rows.removeAll { it.day == day && it.key == key } })
        val day = CycleLogStore.Day(flow = 3, symptoms = setOf("cramps"), moods = setOf("calm"), ovulationTest = true)
        store.save("2026-11-20", day, CycleLogStore.Day())
        assertEquals(day, store.read("2026-11-01", "2026-11-30")["2026-11-20"])
        store.save("2026-11-20", CycleLogStore.Day(moods = setOf("calm")), day)
        assertEquals(listOf("mood.calm"), rows.map { it.key })
        assertNull(store.read("2026-11-01", "2026-11-30")["2026-11-21"])
    }

    @Test fun harderVerdictLeadsTheExerciseCard() {
        val pattern = CoreCycle.Pattern(3, 3, 4, 3, 4, 0.7, mapOf("luteal" to CoreCycle.Verdict("harder", 1.2, null)))
        val push = CyclePush.make(CycleTopic.Exercise, CyclePhase.Luteal, 80.0, pattern)!!
        assertEquals(com.noop.R.string.forge_cy_take_it_a_bit_easier, push.headline.res)
        assertEquals(CyclePush.Tone.Effort, push.tone)
        val primed = CyclePush.make(CycleTopic.Exercise, CyclePhase.Follicular, 80.0, null)!!
        assertEquals(com.noop.R.string.forge_cy_good_day_to_push, primed.headline.res)
        assertNull(CyclePush.make(CycleTopic.Body, CyclePhase.Luteal, 80.0, null))
    }
}
