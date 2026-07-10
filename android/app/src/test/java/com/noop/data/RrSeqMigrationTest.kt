package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Guards the v17 -> v18 Room migration that adds a `seq` tiebreaker to `rrInterval`
 * (PK (deviceId, ts, rrMs) -> (deviceId, ts, rrMs, seq)), plus the [assignRrSeq] insert helper. The
 * value-only key silently dropped the second of two EQUAL R-R intervals in the same 1-second `ts` bucket
 * (insert is `ON CONFLICT DO NOTHING`), biasing RMSSD/HRV high.
 *
 * This environment has no Robolectric / Room-testing, so the migration SQL is pinned to Room's generated
 * shape for [RrInterval] and the insert seq-assignment is proven pure (the actual bug-fix proof, incl. the
 * cross-batch case where distinct same-second beats must NOT collide).
 */
class RrSeqMigrationTest {

    // Compose the on-disk primary key so tests assert real collision behaviour, not just field values.
    private fun pk(r: RrInterval) = listOf(r.deviceId, r.ts, r.rrMs, r.seq)

    @Test
    fun migration_versionPair_is17to18() {
        assertEquals(17, WhoopDatabase.MIGRATION_17_18.startVersion)
        assertEquals(18, WhoopDatabase.MIGRATION_17_18.endVersion)
    }

    @Test
    fun migration_rebuildsTable_losslessly_seqZero_noWindowFns() {
        val sql = WhoopDatabase.RR_SEQ_MIGRATION_SQL
        assertEquals("create, copy, drop, rename", 4, sql.size)
        // The rebuilt table MUST match Room's generated schema for RrInterval exactly (column order + PK),
        // or the no-destructive-fallback open would throw on a schema-identity mismatch.
        assertEquals(
            "CREATE TABLE IF NOT EXISTS `rrInterval_new` (`deviceId` TEXT NOT NULL, `ts` INTEGER NOT NULL, " +
                "`rrMs` INTEGER NOT NULL, `seq` INTEGER NOT NULL, `synced` INTEGER NOT NULL, " +
                "PRIMARY KEY(`deviceId`, `ts`, `rrMs`, `seq`))",
            sql[0],
        )
        // Every existing row copied with seq = 0 (old PK made (deviceId, ts, rrMs) unique, so seq 0 is safe).
        assertEquals(
            "INSERT INTO `rrInterval_new` (`deviceId`, `ts`, `rrMs`, `seq`, `synced`) " +
                "SELECT `deviceId`, `ts`, `rrMs`, 0, `synced` FROM `rrInterval`",
            sql[1],
        )
        assertTrue("preserves history (no DELETE of source before copy)", !sql[1].uppercase().contains("DELETE"))
        assertEquals("DROP TABLE `rrInterval`", sql[2])
        assertEquals("ALTER TABLE `rrInterval_new` RENAME TO `rrInterval`", sql[3])
        assertTrue("no window functions (minSdk26 SQLite)", !sql.joinToString(" ").uppercase().contains("ROW_NUMBER"))
    }

    /** THE fix: two EQUAL intervals in the same second now get distinct keys (the second was dropped before). */
    @Test
    fun assignRrSeq_equalIntervalsSameSecond_survive_withDistinctKeys() {
        val ts = 1_780_916_150L
        val out = assignRrSeq("my-whoop", listOf(RrRow(ts, 600), RrRow(ts, 600), RrRow(ts, 610)))
        assertEquals("nothing dropped", 3, out.size)
        assertEquals("equal (ts,rrMs) beats get 0,1; the distinct 610 gets 0", listOf(0, 1, 0), out.map { it.seq })
        assertEquals(listOf(600, 600, 610), out.map { it.rrMs })
        assertEquals("distinct (deviceId, ts, rrMs, seq) PKs", 3, out.map { pk(it) }.toSet().size)
    }

    /**
     * REGRESSION GUARD (the adversarial-review finding): distinct same-second beats arriving in SEPARATE
     * insert batches (e.g. live 0x2A37 straddling a buffer flush, or the live/historical merge) must NOT
     * collide. Because seq keys on (ts, rrMs), distinct values keep seq 0 and their own PK — no drop.
     */
    @Test
    fun assignRrSeq_distinctBeatsAcrossBatches_doNotCollide() {
        val ts = 1_780_916_150L
        val batch1 = assignRrSeq("d", listOf(RrRow(ts, 600)))   // flush A
        val batch2 = assignRrSeq("d", listOf(RrRow(ts, 560)))   // flush B, same wall-second
        val pks = (batch1 + batch2).map { pk(it) }
        assertEquals("both seq 0 but distinct rrMs → distinct PKs, neither dropped", 2, pks.toSet().size)
        // A ts-only index would have given both seq 0 with rrMs out of the key → identical PK → one dropped.
    }

    /** Re-syncing an identical batch reproduces the same (ts, rrMs, seq) → idempotent (IGNORE dedupes). */
    @Test
    fun assignRrSeq_idempotentOnResync() {
        val batch = listOf(RrRow(100L, 800), RrRow(100L, 800), RrRow(101L, 790))
        val r1 = assignRrSeq("d", batch)
        assertEquals("equal 800s get 0,1; 790 gets 0", listOf(0, 1, 0), r1.map { it.seq })
        assertEquals("same input → same keys", r1.map { pk(it) }, assignRrSeq("d", batch).map { pk(it) })
    }

    /** The real v18 golden record ([602,613]) round-trips: distinct values, both seq 0, both kept. */
    @Test
    fun assignRrSeq_realV18Record() {
        val out = assignRrSeq("my-whoop", listOf(RrRow(1_780_916_150L, 602), RrRow(1_780_916_150L, 613)))
        assertEquals(listOf(602, 613), out.map { it.rrMs })
        assertEquals(listOf(0, 0), out.map { it.seq })
    }
}
