package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v11 -> v12 Room migration (the per-epoch `sleepSession.motionJSON` /
 * `sleepSession.sleepStateJSON` columns) — the Android twin of the Swift WhoopStore v18 migration.
 * This environment has no Robolectric / Room-testing, so the migration's SQL is exposed as an internal
 * constant ([WhoopDatabase.SLEEP_MOTION_STATE_MIGRATION_SQL]) and pinned here to Room's generated shape:
 *
 *  - two ALTER ... ADD COLUMN statements, both nullable TEXT (a `String?` field): no NOT NULL, no DEFAULT.
 *  - ADDITIVE: only ALTER ADD COLUMN; no DROP/DELETE/UPDATE/INSERT/CREATE on existing data.
 */
class SleepMotionStateMigrationTest {

    @Test
    fun migration_isAdditive_onlyAddColumnStatements() {
        val sql = WhoopDatabase.SLEEP_MOTION_STATE_MIGRATION_SQL
        assertEquals("two ADD COLUMN statements", 2, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only ALTER ADD COLUMN allowed, got: $s", up.startsWith("ALTER TABLE") && up.contains("ADD COLUMN"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "CREATE ", "NOT NULL", "DEFAULT")) {
                assertTrue("additive nullable migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_addsExactColumns() {
        assertEquals(
            listOf(
                "ALTER TABLE `sleepSession` ADD COLUMN `motionJSON` TEXT",
                "ALTER TABLE `sleepSession` ADD COLUMN `sleepStateJSON` TEXT",
            ),
            WhoopDatabase.SLEEP_MOTION_STATE_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is11to12() {
        assertEquals(11, WhoopDatabase.MIGRATION_11_12.startVersion)
        assertEquals(12, WhoopDatabase.MIGRATION_11_12.endVersion)
    }
}
