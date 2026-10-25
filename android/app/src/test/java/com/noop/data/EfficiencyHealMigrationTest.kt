package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the v18 -> v19 Room migration (#376): the Oura/WHOOP efficiency-unit HEAL, the byte-parity twin
 * of the Swift WhoopStore `v26-efficiency-heal` GRDB migration. UPDATE-only, NO schema change — divides
 * `sleepSession.efficiency` / `dailyMetric.efficiency` by 100 for every row where it's > 1.5 (a
 * percent-scale leftover from before the importer write-boundary fix), the threshold no genuine 0-1
 * fraction can exceed and no genuine percent can fall under, so the predicate is idempotent.
 *
 * This environment has no Robolectric / Room-testing / JDBC-SQLite (see the other migration tests in this
 * package), so the migration SQL is pinned as a string, the same convention as every other Room migration
 * test here. Unlike the additive migrations elsewhere in this suite (which assert the SQL is ONLY
 * ALTER/CREATE, never UPDATE/DELETE/INSERT), this migration is intentionally UPDATE-only with no schema
 * mutation, so the polarity of the "what's allowed" check is inverted here on purpose.
 */
class EfficiencyHealMigrationTest {

    @Test
    fun migration_versionPair_is18to19() {
        assertEquals(18, WhoopDatabase.MIGRATION_18_19.startVersion)
        assertEquals(19, WhoopDatabase.MIGRATION_18_19.endVersion)
    }

    @Test
    fun migration_healsBothTables_exactSql() {
        assertEquals(
            listOf(
                "UPDATE `sleepSession` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
                "UPDATE `dailyMetric` SET `efficiency` = `efficiency` / 100.0 WHERE `efficiency` > 1.5",
            ),
            WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_isUpdateOnly_noSchemaMutation() {
        // Opposite of the additive migrations' guard: this one must be ONLY an UPDATE (no ALTER/CREATE/
        // DROP/INSERT/DELETE — no schema change, no row added or removed, just an in-place value rescale).
        val sql = WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL
        assertEquals("one UPDATE per healed table", 2, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("must be an UPDATE, got: $s", up.startsWith("UPDATE"))
            for (banned in listOf("ALTER ", "CREATE ", "DROP ", "INSERT ", "DELETE ", "RENAME ")) {
                assertTrue("heal migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_targetsOnlySleepSessionAndDailyMetric() {
        val tables = WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL.map { sql ->
            sql.substringAfter("UPDATE `").substringBefore("`")
        }
        assertEquals(listOf("sleepSession", "dailyMetric"), tables)
    }

    @Test
    fun migration_thresholdAndDivisorMatchTheSwiftHeal() {
        // Same predicate as WhoopStore's v26-efficiency-heal (Database.swift): `> 1.5` / `/ 100.0`, not
        // deviceId-scoped, so both the Oura API importer's and the WHOOP CSV importer's percent-scale rows
        // are healed by the same UPDATE regardless of which strap/brand deviceId they were imported under.
        for (s in WhoopDatabase.EFFICIENCY_HEAL_MIGRATION_SQL) {
            assertTrue("must divide by exactly 100.0: $s", s.contains("/ 100.0"))
            assertTrue("must gate on > 1.5: $s", s.contains("> 1.5"))
            assertTrue("must not scope to a deviceId: $s", !s.uppercase().contains("DEVICEID"))
        }
    }
}
