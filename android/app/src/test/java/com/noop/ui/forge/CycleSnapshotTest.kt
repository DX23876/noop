package com.noop.ui.forge

import com.noop.analytics.CyclePhaseEngine
import com.noop.core.CoreCycle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

/**
 * The cycle page on Android reads what the shared core worked out (the math is tested in `CoreCycleTests`); this
 * checks the reading of the core's answer and the wording the cards pick.
 */
class CycleSnapshotTest {
    private val json = """
        {"today":"2026-11-20","starts":["2026-11-01"],
         "todayLog":{"flow":2,"symptoms":["cramps"],"moods":[],"ovulationTest":false},
         "result":{"phase":"luteal","confidence":"solid","cycleLengthDays":29,"shiftMarkers":["2026-11-15"],"note":"",
                   "nextPeriodWindow":{"earliestDay":"2026-11-28","latestDay":"2026-12-01"},"curve":[0.1]},
         "snapshot":{"cycleDay":20,"length":29,"phase":"luteal","shiftDay":15,"periodLength":5,"nextLow":8,"nextHigh":11,
                     "temps":[{"day":1,"value":0.0},{"day":20,"value":0.4}],"startDay":"2026-11-01","periodDays":["2026-11-01"],
                     "compare":{"tempDelta":0.4,"rhrDelta":3},"cyclesSeen":1,"confidence":"solid","moodsThisPhase":{"calm":2},
                     "fertile":{"firstDay":8,"lastDay":14,"basis":"confirmedByRise","pastRiseDays":[],"status":"over"},
                     "fertileDays":["2026-11-08"],"dayPhases":["period","period","period","period","period","follicular"]}}
    """.trimIndent()

    @Test fun theCoresAnswerReadsIntoThePage() {
        val out = CoreCycle.parseOutput(json)!!
        assertEquals(CyclePhaseEngine.Phase.LUTEAL, out.result!!.phase)
        assertEquals("2026-11-28", out.result!!.nextPeriodWindow!!.earliestDay)
        assertEquals(CoreCycle.LogDay(flow = 2, symptoms = setOf("cramps")), out.todayLog)
        val snap = CycleSnapshot.from(out.snapshot)
        assertEquals(20, snap.cycleDay); assertEquals(CyclePhase.Luteal, snap.phase)
        assertEquals(LocalDate.parse("2026-11-01"), snap.startDate)
        assertEquals(8..11, snap.nextWindow)
        assertEquals(CyclePhase.Period, snap.phase(1)); assertEquals(CyclePhase.Follicular, snap.phase(6)); assertNull(snap.phase(30))
        assertEquals(0.4, snap.compare!!.tempDelta!!, 1e-9)
        assertEquals(com.noop.R.string.forge_cy_fertile_days_are_over, snap.fertileLine!!.first.res)
        assertNull(snap.fertileStartAhead)
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
