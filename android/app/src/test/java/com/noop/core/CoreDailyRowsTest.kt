package com.noop.core

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The core's daily rows parse into Room's shape, and the comparison names each disagreeing field once. */
class CoreDailyRowsTest {
    @Test fun parsesSwiftRowsAndComparesFieldByField() {
        val core = CoreDailyRows.parse("""[{"day":"2026-10-20","totalSleepMin":383,"recovery":38,"steps":9874,"sleepHrOnly":false},
            {"day":"2026-10-21","recovery":50}]""", "my-whoop")!!
        assertEquals(2, core.size)
        assertEquals(9874, core[0].steps)
        assertEquals(false, core[0].sleepHrOnly)
        val room = listOf(DailyMetric("my-whoop", "2026-10-20", totalSleepMin = 383.0, recovery = 38.0))
        val diffs = CoreDailyRows.compare(room, core)
        assertEquals(listOf("steps", "row"), diffs.map { it.field })
        assertTrue(CoreDailyRows.compare(core, core).isEmpty())
    }
}
