package com.noop.core

import com.noop.data.WorkoutRow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The core's workout rows parse into Room's shape, take Room's keys and routes, and the comparison names each disagreeing field. */
class CoreWorkoutRowsTest {
    @Test fun parsesSwiftRowsTakesRoomKeysAndCompares() {
        val core = CoreWorkoutRows.parse("""[{"startTs":200,"endTs":260,"sport":"Run","source":"my-whoop","avgHr":140,"steps":null},
            {"startTs":100,"endTs":130,"sport":"Walk","source":"health-connect","distanceM":2100.5}]""")!!
        assertEquals(2, core.size)
        assertEquals("my-whoop", core[0].deviceId)
        assertEquals(140, core[0].avgHr)
        assertNull(core[0].steps)

        val room = listOf(WorkoutRow("my-whoop", 200, 260, "Run", "my-whoop", avgHr = 138, routePolyline = "abc"))
        assertEquals("abc", CoreWorkoutRows.withRoomKeys(core, room)[0].routePolyline)
        assertNull(CoreWorkoutRows.withRoomKeys(core, room)[1].routePolyline)

        val diffs = CoreWorkoutRows.compare(room, core)
        assertEquals(listOf("row", "avgHr"), diffs.map { it.field })
        assertTrue(CoreWorkoutRows.compare(core, core).isEmpty())
    }

    /**
     * A manual session lives under the strap's id with source "manual": the core row must carry Room's id, or a
     * delete by Room's key (deviceId, startTs, sport) finds nothing and the session stays.
     */
    @Test fun coreRowsTakeRoomDeviceIdForDeleteAndDismiss() {
        val core = CoreWorkoutRows.parse("""[{"startTs":500,"endTs":900,"sport":"Strength","source":"manual"},
            {"startTs":300,"endTs":400,"sport":"Running","source":"oura"},
            {"startTs":50,"endTs":60,"sport":"Ride","source":"apple-health"}]""")!!
        val room = listOf(
            WorkoutRow("AA:BB:CC", 500, 900, "Strength", "manual"),
            WorkoutRow("my-whoop", 500, 900, "Strength", "manual"),
            WorkoutRow("oura", 300, 400, "running", "oura", routePolyline = "r"),
        )
        val keyed = CoreWorkoutRows.withRoomKeys(core, room)
        assertEquals("AA:BB:CC", keyed[0].deviceId)
        // The core normalised the sport; start and source still name the one stored row.
        assertEquals("oura", keyed[1].deviceId)
        assertEquals("r", keyed[1].routePolyline)
        // Room has no such row: the source stays as id, and the comparison reports it.
        assertEquals("apple-health", keyed[2].deviceId)
        // A row keyed to the wrong id is a difference the Lab check names.
        assertEquals(listOf("deviceId"), CoreWorkoutRows.compare(room.take(1), listOf(keyed[0].copy(deviceId = "manual"))).map { it.field })
    }
}
