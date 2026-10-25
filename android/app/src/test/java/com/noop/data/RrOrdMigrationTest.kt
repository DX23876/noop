package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.sqrt

/**
 * #823: R-R beats must be READ in the order the heart produced them, not sorted by value.
 *
 * Guards the additive `ord` migration and the [assignRrSeq] stamping. The read order itself is SQL
 * and is exercised end-to-end on the Swift twin (WhoopStoreTests MigrationTests, which CI actually
 * runs); these JVM tests assert the migration shape and the pure stamping function, matching how the
 * other migrations here are covered — there is no SQLite driver on the unit-test classpath.
 */
class RrOrdMigrationTest {

    @Test
    fun migrationIsAdditiveNullableAndNotAKeyChange() {
        val sql = WhoopDatabase.RR_ORD_MIGRATION_SQL
        assertEquals(1, sql.size)
        // Nullable INTEGER: no NOT NULL, no DEFAULT. NULL means "emission order unknown", which is
        // every pre-v24 row — it was never recorded, so it cannot be backfilled.
        assertEquals("ALTER TABLE `rrInterval` ADD COLUMN `ord` INTEGER", sql[0])
        val upper = sql[0].uppercase()
        assertTrue(upper.startsWith("ALTER TABLE"))
        assertTrue("must be additive", upper.contains("ADD COLUMN"))
        assertFalse("ord must be nullable", upper.contains("NOT NULL"))
        assertFalse("no default — absent means unknown", upper.contains("DEFAULT"))
        for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ", "PRIMARY KEY")) {
            assertFalse("migration must not contain $banned", upper.contains(banned))
        }
        assertEquals(23, WhoopDatabase.MIGRATION_23_24.startVersion)
        assertEquals(24, WhoopDatabase.MIGRATION_23_24.endVersion)
    }

    @Test
    fun ord_numbersEveryBeatInTheSecondInEmissionOrder() {
        val ts = 1_780_916_150L
        val emission = listOf(812, 795, 840, 801, 833)
        val out = assignRrSeq("d", emission.map { RrRow(ts, it) })

        assertEquals("stamped in arrival order", listOf(0, 1, 2, 3, 4), out.map { it.ord })
        assertEquals("rrMs untouched", emission, out.map { it.rrMs })
        // seq is 0 for every DISTINCT beat — which is precisely why it cannot carry emission order,
        // and why the two-line `ORDER BY ts, seq` fix would have made the order undefined instead.
        assertEquals(listOf(0, 0, 0, 0, 0), out.map { it.seq })
    }

    @Test
    fun ord_isPerSecond_andRestartsOnTheNextSecond() {
        val out = assignRrSeq(
            "d",
            listOf(RrRow(100L, 812), RrRow(100L, 795), RrRow(101L, 840), RrRow(101L, 801)),
        )
        assertEquals(listOf(0, 1, 0, 1), out.map { it.ord })
    }

    @Test
    fun ord_andSeq_areIndependent_equalBeatsGetDistinctBoth() {
        // Two EQUAL beats plus a distinct one. seq disambiguates the equal pair for the KEY;
        // ord records where all three sat in the second. Neither substitutes for the other.
        val out = assignRrSeq("d", listOf(RrRow(100L, 600), RrRow(100L, 600), RrRow(100L, 610)))
        assertEquals(listOf(0, 1, 0), out.map { it.seq })
        assertEquals(listOf(0, 1, 2), out.map { it.ord })
        assertEquals("all three keep distinct keys", 3, out.map { "${it.ts}/${it.rrMs}/${it.seq}" }.toSet().size)
    }

    @Test
    fun ord_doesNotDisturbTheKey_soResyncStaysIdempotent() {
        val batch = listOf(RrRow(100L, 812), RrRow(100L, 795), RrRow(100L, 812))
        fun keys(rows: List<RrInterval>) = rows.map { "${it.deviceId}/${it.ts}/${it.rrMs}/${it.seq}" }
        assertEquals("same input → same keys", keys(assignRrSeq("d", batch)), keys(assignRrSeq("d", batch)))
        assertEquals("same input → same ord", assignRrSeq("d", batch).map { it.ord },
            assignRrSeq("d", batch).map { it.ord })
    }

    @Test
    fun entityDefaultsOrdToNull_soLegacyRowsStayHonest() {
        // A row constructed without ord (any pre-#823 call site, or a source that cannot supply it)
        // records "unknown" rather than guessing 0, which would assert an order nobody observed.
        assertNull(RrInterval(deviceId = "d", ts = 1L, rrMs = 800).ord)
    }

    /**
     * The consequence being fixed, on the issue's own example. Not a test of the SQL — a guard on the
     * claim that motivates the schema change, so the number stays honest if anyone revisits it.
     */
    @Test
    fun magnitudeOrderBiasesRmssdDownByAbout22ms() {
        fun rmssd(v: List<Int>): Double {
            val d = v.zipWithNext { a, b -> (b - a).toDouble() * (b - a) }
            return sqrt(d.sum() / d.size)
        }
        val emission = listOf(812, 795, 840, 801, 833)
        assertEquals(34.85, rmssd(emission), 0.01)
        assertEquals(12.72, rmssd(emission.sorted()), 0.01)
        assertTrue("sorting biases RMSSD DOWN, never up", rmssd(emission.sorted()) < rmssd(emission))
    }
}
