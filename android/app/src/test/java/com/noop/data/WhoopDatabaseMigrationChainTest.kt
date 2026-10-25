package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The registered migration chain must have no holes and must reach [WhoopDatabase.SCHEMA_VERSION].
 *
 * The existing migration tests each assert one migration's SQL and its start/end versions. None of them
 * asserts that it is REGISTERED, so a migration could be written, tested, reviewed and still left out of
 * `addMigrations(...)`. Sabotage confirmed it: removing an entry from the chain left the whole suite
 * green, and removing an OLDER entry did too — this was a property of the suite, not of any one change.
 *
 * The consequence is bounded but real. There is deliberately no destructive fallback, so a hole makes
 * Room throw on upgrade rather than silently rebuild — a loud failure for every existing user on the
 * version that ships it. With `exportSchema=false` nothing else catches it first.
 *
 * Android-only by nature: GRDB registers migrations by name in one sequential `migrator` block, so a
 * Swift migration cannot be declared-but-unregistered the way a Room one can.
 */
class WhoopDatabaseMigrationChainTest {

    private val chain = WhoopDatabase.ALL_MIGRATIONS.sortedBy { it.startVersion }

    /** Every step must advance, and no two may start from the same version. */
    @Test
    fun eachMigrationAdvancesAndNoTwoStartFromTheSameVersion() {
        for (m in chain) {
            assertTrue("migration ${m.startVersion}->${m.endVersion} does not advance",
                       m.endVersion > m.startVersion)
        }
        val starts = chain.map { it.startVersion }
        assertEquals("two migrations start from the same version: $starts",
                     starts.size, starts.toSet().size)
    }

    /**
     * No holes. Walk the chain from its lowest start version and require each migration to begin exactly
     * where the previous one ended.
     *
     * Deliberately anchored to the chain's own lowest version rather than 1: v1 predates this regime and
     * has no upgrade path, so asserting coverage from 1 would be asserting something untrue.
     */
    @Test
    fun theChainHasNoHoles() {
        assertTrue("no migrations registered at all", chain.isNotEmpty())
        var reached = chain.first().startVersion
        for (m in chain) {
            assertEquals(
                "hole in the migration chain: nothing upgrades $reached -> ${m.startVersion}",
                reached, m.startVersion,
            )
            reached = m.endVersion
        }
    }

    /**
     * The chain must end exactly at [WhoopDatabase.SCHEMA_VERSION].
     *
     * Catches the other half of the mistake: bumping [WhoopDatabase.SCHEMA_VERSION] and forgetting the
     * migration, which fails the same way on upgrade. Note that SCHEMA_VERSION is a hand-maintained
     * constant, NOT the `@Database(version = ...)` Room actually opens with - the two are tied together
     * by [theRoomAnnotationVersionMatchesSchemaVersion] below, not here.
     */
    @Test
    fun theChainReachesTheDeclaredSchemaVersion() {
        // Guarded like theChainHasNoHoles: an empty chain should fail with this message rather than
        // throw NoSuchElementException out of last(), which reads as a broken test rather than a
        // broken chain — and an empty chain is exactly the catastrophic case worth naming clearly.
        assertTrue("no migrations registered at all", chain.isNotEmpty())
        assertEquals(
            "chain ends at ${chain.last().endVersion} but SCHEMA_VERSION is ${WhoopDatabase.SCHEMA_VERSION}",
            WhoopDatabase.SCHEMA_VERSION, chain.last().endVersion,
        )
    }

    /**
     * `@Database(version = ...)` must equal [WhoopDatabase.SCHEMA_VERSION].
     *
     * This is the third leg, and the one #1709 fell through: it removed an entity, registered
     * MIGRATION_34_35 and bumped SCHEMA_VERSION to 35, but left the annotation at 34. Every test above
     * passed, because the chain agreed with SCHEMA_VERSION and nothing compared either to the number
     * Room opens the database with.
     *
     * The consequence is the worst-shaped kind. Room hashes the declared entity set into
     * `room_master_table` and re-checks it on open, so a changed schema under an unchanged version
     * throws "Room cannot verify the data integrity" for every EXISTING install, on launch, before any
     * UI. A fresh install writes the hash from the new schema and runs perfectly - so emulators, CI and
     * every test here stay green while the shipped build crashes on exactly the devices that have data.
     *
     * Read from source text rather than reflection: androidx.room.Database is CLASS-retention, so it is
     * absent at runtime and a reflective read would quietly return null and assert nothing.
     */
    @Test
    fun theRoomAnnotationVersionMatchesSchemaVersion() {
        var root = java.io.File(System.getProperty("user.dir") ?: ".").canonicalFile
        var source: String? = null
        repeat(4) {
            val f = java.io.File(root, "android/app/src/main/java/com/noop/data/WhoopDatabase.kt")
            if (f.isFile && source == null) source = f.readText()
            root = root.parentFile ?: root
        }
        val text = source ?: error("WhoopDatabase.kt not found - this test must not pass by default")
        val declared = Regex("""@Database\(.*?\bversion\s*=\s*(\d+)""", RegexOption.DOT_MATCHES_ALL)
            .find(text)?.groupValues?.get(1)?.toInt()
            ?: error("could not read @Database(version = ...) - this test must not pass by default")
        assertEquals(
            "@Database(version = $declared) but SCHEMA_VERSION is ${WhoopDatabase.SCHEMA_VERSION}. " +
                "Room opens with the annotation; a mismatch crashes every existing install on launch.",
            WhoopDatabase.SCHEMA_VERSION, declared,
        )
    }
}
