package com.noop.core

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The core's workout rows parse into Room's shape, keep Room's routes, and the comparison names each disagreeing field. */
class CoreWorkoutRowsTest {
    @Test fun parsesSwiftRowsKeepsRoutesAndCompares() {
        val core = CoreWorkoutRows.parse("""[{"startTs":200,"endTs":260,"sport":"Run","source":"my-whoop","avgHr":140,"steps":null},
            {"startTs":100,"endTs":130,"sport":"Walk","source":"health-connect","distanceM":2100.5}]""")!!
        assertEquals(2, core.size)
        assertEquals("my-whoop", core[0].deviceId)
        assertEquals(140, core[0].avgHr)
        assertNull(core[0].steps)

        val room = listOf(WorkoutRow("my-whoop", 200, 260, "Run", "my-whoop", avgHr = 138, routePolyline = "abc"))
        assertEquals("abc", CoreWorkoutRows.withRoutes(core, room)[0].routePolyline)
        assertNull(CoreWorkoutRows.withRoutes(core, room)[1].routePolyline)

        val diffs = CoreWorkoutRows.compare(room, core)
        assertEquals(listOf("row", "avgHr"), diffs.map { it.field })
        assertTrue(CoreWorkoutRows.compare(core, core).isEmpty())
    }
}
