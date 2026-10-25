package com.noop.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

/** Guards the additive #515 follow-up that lets the Sleep screen hide stale recompute rows without
 * deleting the tombstones that keep mistaken sleep from being detected again. */
class DismissedSleepVisibilityMigrationTest {

    @Test
    fun migrationAddsVisibleFlagWithoutTouchingRows() {
        val sql = WhoopDatabase.DISMISSED_SLEEP_VISIBILITY_MIGRATION_SQL
        assertEquals(
            listOf(
                "ALTER TABLE `dismissedSleep` ADD COLUMN `managementVisible` INTEGER NOT NULL DEFAULT 1",
            ),
            sql,
        )
        for (statement in sql) {
            val upper = statement.uppercase()
            assertTrue(upper.startsWith("ALTER TABLE") && upper.contains("ADD COLUMN"))
            for (banned in listOf("DROP ", "DELETE ", "UPDATE ", "INSERT ")) {
                assertFalse("migration must not contain $banned", upper.contains(banned))
            }
        }
        assertEquals(21, WhoopDatabase.MIGRATION_21_22.startVersion)
        assertEquals(22, WhoopDatabase.MIGRATION_21_22.endVersion)
    }

    @Test
    fun newTombstonesRemainVisibleByDefault() {
        assertTrue(DismissedSleep("my-whoop-noop", 100L, 200L).managementVisible)
    }

    @Test
    fun hiddenMarkerStillReachesDetectorButNotManagementList() = runBlocking {
        val hidden = DismissedSleep("my-whoop", 100L, 200L, managementVisible = false)
        val shown = DismissedSleep("my-whoop-noop", 300L, 400L)
        val dao = proxyDao { method, _ ->
            when (method) {
                "dismissedSleeps" -> listOf(hidden, shown)
                else -> throw UnsupportedOperationException(method)
            }
        }
        val repo = WhoopRepository(dao)

        assertTrue("detector-facing read must retain hidden tombstones", repo.dismissedSleeps().contains(hidden))
        assertEquals(listOf(shown), repo.dismissedSleepsUnion("my-whoop"))
    }

    @Test
    fun hideUpdatesOnlyTheSelectedTombstone() = runBlocking {
        var key: Pair<String, Long>? = null
        val dao = proxyDao { method, args ->
            when (method) {
                "hideDismissedSleepFromManagement" -> {
                    key = args[0] as String to args[1] as Long
                    1
                }
                else -> throw UnsupportedOperationException(method)
            }
        }

        assertTrue(WhoopRepository(dao).hideDeletedSleepWindow("strap-noop", 123L))
        assertEquals("strap-noop" to 123L, key)
    }

    private fun proxyDao(call: (String, Array<out Any?>) -> Any?): WhoopDao =
        Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args -> call(method.name, args ?: emptyArray()) } as WhoopDao
}
