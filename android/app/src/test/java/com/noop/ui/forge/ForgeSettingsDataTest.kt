package com.noop.ui.forge

import com.noop.core.CoreAnalysisMaintenance
import com.noop.core.CoreStorage
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the Calculations and Storage pages read from the core (`analysis.maintenance`, `storage.report`). */
class ForgeSettingsDataTest {
    @Test fun anIdleEngineReadsAsNothingRunning() {
        val s = CoreAnalysisMaintenance.parseStatus(JSONObject("""{"phase":"idle","lastRun":1700000500,"completedAt":1700000500}"""))
        assertFalse(s.working)
        assertNull(s.task)
        assertEquals(1700000500L, s.lastRunSeconds)
        assertNull(s.progress)
        assertNull(s.failure)
    }

    @Test fun aRunningPassCarriesTheCoresEstimateAndStallVerdict() {
        val s = CoreAnalysisMaintenance.parseStatus(JSONObject(
            """{"phase":"working","task":"recent","progress":{"stage":"scanning","fraction":0.25,"day":6,"totalDays":21,
               "unchanged":2,"eta":{"value":2,"unit":"min"},"gap":{"value":5,"unit":"s"},"stalled":false}}"""))
        assertTrue(s.working)
        assertEquals("recent", s.task)
        val p = s.progress!!
        assertEquals(6, p.day)
        assertEquals(21, p.totalDays)
        assertEquals(2, p.unchanged)
        assertEquals(CoreAnalysisMaintenance.Status.Coarse(2, "min"), p.eta)
        assertEquals(CoreAnalysisMaintenance.Status.Coarse(5, "s"), p.gap)
        assertFalse(p.stalled)
    }

    @Test fun anEstimateTheCoreWithheldStaysAbsent() {
        val s = CoreAnalysisMaintenance.parseStatus(JSONObject(
            """{"phase":"working","task":"today","failure":"noCurrentDayActivity",
               "progress":{"stage":"preparing","fraction":0,"day":1,"totalDays":21,"unchanged":0,"gap":{"value":5,"unit":"s"},"stalled":true}}"""))
        assertNull(s.progress!!.eta)
        assertTrue(s.progress!!.stalled)
        assertEquals("noCurrentDayActivity", s.failure)
    }

    @Test fun theDatabaseSizeIsAbsentWhenTheCoreHasNoFile() {
        assertEquals(1_234_567L, CoreStorage.parseBytes(JSONObject("""{"db":1234567}""")))
        assertNull(CoreStorage.parseBytes(JSONObject("{}")))
        assertNull(CoreStorage.parseBytes(JSONObject("""{"db":null}""")))
    }
}
