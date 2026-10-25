package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guards the additive score-input provenance schema and its metric-level natural key. */
class ScoreInputProvenanceMigrationTest {
    @Test
    fun migrationIsAdditiveAndMatchesEntityShape() {
        val sql = WhoopDatabase.SCORE_INPUT_PROVENANCE_MIGRATION_SQL
        assertEquals(2, sql.size)
        assertEquals(
            "CREATE TABLE IF NOT EXISTS `scoreInputProvenance` (`deviceId` TEXT NOT NULL, " +
                "`day` TEXT NOT NULL, `key` TEXT NOT NULL, `sourceId` TEXT NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `day`, `key`))",
            sql[0],
        )
        assertEquals(
            "CREATE INDEX IF NOT EXISTS `idx_scoreInputProvenance_source` " +
                "ON `scoreInputProvenance` (`sourceId`)",
            sql[1],
        )
        for (statement in sql) {
            val upper = statement.uppercase()
            assertTrue(upper.startsWith("CREATE "))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "ALTER ")) {
                assertFalse("migration must not contain $banned", upper.contains(banned))
            }
        }
        assertEquals(22, WhoopDatabase.MIGRATION_22_23.startVersion)
        assertEquals(23, WhoopDatabase.MIGRATION_22_23.endVersion)
    }
}
