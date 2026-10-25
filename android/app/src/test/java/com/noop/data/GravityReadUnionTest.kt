package com.noop.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

/** Regression coverage for the gravity read used by the Steps calibration screen (#1643). */
class GravityReadUnionTest {

    private val canonical = WhoopRepository.WHOOP_SOURCE
    private val active = "whoop-abc"

    private fun sample(deviceId: String, ts: Long, x: Double) =
        GravitySample(deviceId = deviceId, ts = ts, x = x, y = 0.0, z = 1.0)

    @Test
    fun activeOnlyMotionIsSurfacedWhenCanonicalIsEmpty() {
        val activeRows = listOf(
            sample(active, 100, 0.1),
            sample(active, 101, 0.2),
        )
        val byId = mapOf(active to activeRows, canonical to emptyList())

        val ids = WhoopRepository.importedSourceIdsFor(active)
        val merged = WhoopRepository.mergeGravityByTs(ids.map { byId.getValue(it) })

        assertEquals(listOf(active, canonical), ids)
        assertEquals(activeRows, merged)
    }

    @Test
    fun activeAndCanonicalHistoryMergeInTimestampOrderWithActiveWinningTies() {
        val activeRows = listOf(
            sample(active, 101, 9.0),
            sample(active, 103, 9.2),
        )
        val canonicalRows = listOf(
            sample(canonical, 100, 5.0),
            sample(canonical, 101, 5.1),
            sample(canonical, 102, 5.2),
        )

        val merged = WhoopRepository.mergeGravityByTs(listOf(activeRows, canonicalRows))

        assertEquals(listOf(100L, 101L, 102L, 103L), merged.map { it.ts })
        assertEquals(active, merged.first { it.ts == 101L }.deviceId)
        assertEquals(9.0, merged.first { it.ts == 101L }.x, 0.0)
    }

    @Test
    fun canonicalActiveIdKeepsTheExistingSingleReadUnchanged() {
        val rows = listOf(
            sample(canonical, 100, 0.1),
            sample(canonical, 101, 0.2),
        )

        val ids = WhoopRepository.importedSourceIdsFor(canonical)
        val merged = WhoopRepository.mergeGravityByTs(listOf(rows))

        assertEquals(listOf(canonical), ids)
        assertSame(rows, merged)
    }

    @Test
    fun noMotionUnderEitherIdStaysEmpty() {
        val merged = WhoopRepository.mergeGravityByTs(listOf(emptyList(), emptyList()))

        assertEquals(emptyList<GravitySample>(), merged)
    }
}
