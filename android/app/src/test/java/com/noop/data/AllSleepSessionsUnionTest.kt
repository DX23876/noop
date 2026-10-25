package com.noop.data

import java.lang.reflect.Proxy
import java.util.TimeZone
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * Rhythm's read path (`RhythmRoute.loadRhythmData`) used to call `sleepSessionsMerged`, scoped to just
 * (activeDeviceId, canonical "my-whoop") — an archived third strap's nights were invisible to it, despite
 * doc comments claiming parity with Swift `Repository.allSleepSessions`. [WhoopRepository.allSleepSessionsUnion]
 * is the actual twin: built from [WhoopRepository.sleepSessionsUnion] / [WhoopRepository.computedSleepSessionsUnion]
 * (the full-registry unions, robust to a stale/wrong active id), with an imported-day-excludes-computed-day
 * merge — no richness exception, unlike [WhoopRepository.mergeSleepRichness].
 *
 * Pinned to a fixed UTC default zone so the local-wake-day keying is deterministic (mirrors
 * [MergeSleepLocalDayTest]'s approach).
 */
class AllSleepSessionsUnionTest {
    private val saved: TimeZone = TimeZone.getDefault()

    @Before fun setUtc() { TimeZone.setDefault(TimeZone.getTimeZone("UTC")) }

    @After fun restore() { TimeZone.setDefault(saved) }

    private fun device(id: String, status: String, addedAt: Long, brand: String = "WHOOP") =
        PairedDeviceRow(id, brand, "test", null, null, "whoop", "hr", status, addedAt, addedAt)

    private val allWhoops = listOf(
        device("whoop-old", "archived", 1),
        device("my-whoop", "paired", 2),
        device("whoop-new", "active", 3),
    )

    @Test
    fun activeRingNightWinsOverOverlappingImportedWhoopNight() = runBlocking {
        val start = System.currentTimeMillis() / 1000L - 86_400L
        val ring = SleepSession(deviceId = "oura-ring", startTs = start, endTs = start + 38_400)
        val imported = SleepSession(deviceId = "my-whoop", startTs = start + 574, endTs = start + 37_976)
        val repo = WhoopRepository(proxyDao(mapOf("oura-ring" to listOf(ring), "my-whoop" to listOf(imported))))

        val sessions = repo.allSleepSessionsUnion("oura-ring")

        assertEquals(listOf("oura-ring"), sessions.map { it.deviceId })
    }

    private fun proxyDao(rows: Map<String, List<SleepSession>>): WhoopDao =
        Proxy.newProxyInstance(
            WhoopDao::class.java.classLoader,
            arrayOf(WhoopDao::class.java),
        ) { _, method, args ->
            when (method.name) {
                "pairedDevice", "activeDeviceId" -> null
                "hasWhoop5RrSource" -> false
                "pairedDevices" -> allWhoops
                "sleepSessions" -> rows[args[0] as String].orEmpty()
                else -> throw UnsupportedOperationException(method.name)
            }
        } as WhoopDao

    @Test
    fun archivedThirdStrapNightSurfacesEvenWhenNeitherActiveNorCanonical() = runBlocking {
        // A night banked only under "whoop-old" — neither the active strap ("whoop-new") nor the
        // canonical import bucket ("my-whoop"). sleepSessionsMerged(deviceId) would have missed it
        // entirely, since importedSourceIdsFor only ever unions (deviceId, "my-whoop").
        val archivedNight = SleepSession(deviceId = "whoop-old", startTs = 1_000, endTs = 30_000)
        val repo = WhoopRepository(proxyDao(mapOf("whoop-old" to listOf(archivedNight))))

        val sessions = repo.allSleepSessionsUnion("whoop-new", days = 4000)

        assertEquals(listOf(1_000L), sessions.map { it.startTs })
    }

    @Test
    fun importedWinsOverComputedOnTheSameLocalWakeDay() = runBlocking {
        // Both end within the same UTC day (2026-06-14); the computed twin has no richness exception
        // to fall back on here, unlike mergeSleepRichness, so it must simply be excluded.
        val dayEnd = 1_781_476_800L // 2026-06-14 22:40:00 UTC
        val imported = SleepSession(deviceId = "whoop-new", startTs = dayEnd - 8 * 3_600L, endTs = dayEnd)
        val computed = SleepSession(
            deviceId = "whoop-new-noop",
            startTs = dayEnd - 7 * 3_600L,
            endTs = dayEnd - 3_600L,
        )
        val repo = WhoopRepository(
            proxyDao(mapOf("whoop-new" to listOf(imported), "whoop-new-noop" to listOf(computed))),
        )

        val sessions = repo.allSleepSessionsUnion("whoop-new", days = 4000)

        assertEquals("computed session on an already-imported local day must be dropped", 1, sessions.size)
        assertEquals(imported.startTs, sessions.single().startTs)
    }

    @Test
    fun resultIsSortedAscendingSoLastIsTheMostRecentNight() = runBlocking {
        val older = SleepSession(deviceId = "whoop-old", startTs = 1_000, endTs = 30_000)
        val newest = SleepSession(deviceId = "whoop-new", startTs = 200_000, endTs = 230_000)
        val middle = SleepSession(deviceId = "my-whoop", startTs = 100_000, endTs = 130_000)
        // Insertion order deliberately NOT chronological: newest strap is queried first by
        // rawWhoopSourceIdsFor (active-first ordering), so an unsorted union would put "newest" first.
        val repo = WhoopRepository(
            proxyDao(
                mapOf(
                    "whoop-new" to listOf(newest),
                    "whoop-old" to listOf(older),
                    "my-whoop" to listOf(middle),
                ),
            ),
        )

        val sessions = repo.allSleepSessionsUnion("whoop-new", days = 4000)

        assertEquals(listOf(older.startTs, middle.startTs, newest.startTs), sessions.map { it.startTs })
        assertEquals(newest.startTs, sessions.last().startTs)
    }
}
