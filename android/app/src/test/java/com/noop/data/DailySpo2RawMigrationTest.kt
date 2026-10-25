package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the additive v16 -> v17 Room migration (the raw SpO2 red/IR ADC columns on `dailyMetric`, #93),
 * the Android twin of the Swift WhoopStore v23 migration. No Robolectric here, so the migration SQL is
 * exposed as an internal constant ([WhoopDatabase.DAILY_SPO2_RAW_MIGRATION_SQL]) and pinned to Room's
 * generated shape for the two nullable Int columns: `ALTER TABLE ADD COLUMN ... INTEGER` (no NOT NULL,
 * no DEFAULT), so an in-place upgrade of an older database keeps every existing row (columns read NULL).
 */
class DailySpo2RawMigrationTest {

    @Test
    fun migration_isAdditive_onlyAddColumn() {
        val sql = WhoopDatabase.DAILY_SPO2_RAW_MIGRATION_SQL
        assertEquals("two ADD COLUMN statements", 2, sql.size)
        for (s in sql) {
            val up = s.trimStart().uppercase()
            assertTrue("only ALTER TABLE ADD COLUMN allowed, got: $s", up.startsWith("ALTER TABLE"))
            assertTrue("must be an ADD COLUMN, got: $s", up.contains("ADD COLUMN"))
            // Nullable columns: Room emits no NOT NULL / no DEFAULT for an Int?; a NOT NULL add without a
            // default would fail on a non-empty table (the older-DB regression this guards against).
            assertTrue("nullable column must not be NOT NULL: $s", !up.contains("NOT NULL"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "RENAME ")) {
                assertTrue("additive migration must not contain '$banned': $s", !up.contains(banned))
            }
        }
    }

    @Test
    fun migration_addsExactColumns() {
        assertEquals(
            listOf(
                "ALTER TABLE `dailyMetric` ADD COLUMN `spo2Red` INTEGER",
                "ALTER TABLE `dailyMetric` ADD COLUMN `spo2Ir` INTEGER",
            ),
            WhoopDatabase.DAILY_SPO2_RAW_MIGRATION_SQL,
        )
    }

    @Test
    fun migration_versionPair_is16to17() {
        assertEquals(16, WhoopDatabase.MIGRATION_16_17.startVersion)
        assertEquals(17, WhoopDatabase.MIGRATION_16_17.endVersion)
    }

    @Test
    fun dailyMetric_rawSpo2Fields_defaultNull() {
        // Old rows + non-4.0 nights never set these; the entity default must be null so the merge +
        // Room round-trip leave pre-upgrade data untouched.
        val bare = DailyMetric(deviceId = "my-whoop", day = "2026-07-03")
        assertEquals(null, bare.spo2Red)
        assertEquals(null, bare.spo2Ir)
        val filled = bare.copy(spo2Red = 31000, spo2Ir = 28000)
        assertEquals(31000, filled.spo2Red)
        assertEquals(28000, filled.spo2Ir)
    }
}
