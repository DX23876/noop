package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the all-groups bridge (#364): the SAME two-tier gap bridge the main-night selector applies
 * (#561 short-wake + #861 overnight night-tail), returned for EVERY group with each group's
 * inter-fragment wake seams explicit — so the Health Connect export and the Sleep screen can present
 * a briefly-interrupted night as ONE night without re-deriving (or diverging from) the bridge.
 *
 * Faithful Kotlin mirror of BridgedNightGroupsTests.swift: same fixtures, same expected values.
 */
class BridgedNightGroupsTest {

    /** 2026-01-02 00:00:00 UTC — fixtures read as local clock times with offsetSec 0. */
    private val t0 = 1_767_312_000L
    private fun b(start: Long, end: Long) = SleepStageTotals.NightBlock(start, end)

    @Test
    fun shortWakeBridgesTwoFragmentsWithOneGap() {
        // The #364 example shape: 23:00→02:00, a 16-minute wake, 02:16→06:00.
        val a = b(t0 - 3_600, t0 + 2 * 3_600)
        val c = b(t0 + 2 * 3_600 + 16 * 60, t0 + 6 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c), 0L)
        assertEquals(1, groups.size)
        assertEquals(listOf(0, 1), groups[0].indices)
        assertEquals(listOf(a.end to c.start), groups[0].gaps)
    }

    @Test
    fun daytimeNapStaysItsOwnGroup() {
        val night = b(t0 - 3_600, t0 + 6 * 3_600)              // 23:00→06:00
        val nap = b(t0 + 14 * 3_600, t0 + 15 * 3_600)          // 14:00→15:00
        val groups = SleepStageTotals.bridgedNightGroups(listOf(night, nap), 0L)
        assertEquals(listOf(listOf(0), listOf(1)), groups.map { it.indices })
        assertTrue(groups.all { it.gaps.isEmpty() })
    }

    @Test
    fun nightTailBridgesOvernightGapOverSixtyMinutes() {
        // 75-min gap with the second fragment's onset at 04:15 local (overnight band): folded in by
        // the #861 night-tail bridge, so a longer real mid-night wake still reads as one night.
        val a = b(t0 - 3_600, t0 + 3 * 3_600)
        val c = b(t0 + 3 * 3_600 + 75 * 60, t0 + 7 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c), 0L)
        assertEquals(listOf(listOf(0, 1)), groups.map { it.indices })
        assertEquals(listOf(a.end to c.start), groups[0].gaps)
    }

    @Test
    fun daytimeGapOverSixtyMinutesDoesNotBridge() {
        // Same 75-min gap but the second fragment begins at 13:15 local (daytime): the night-tail
        // widening must NOT apply, so the blocks stay separate groups (a real afternoon nap).
        val a = b(t0 + 9 * 3_600, t0 + 12 * 3_600)
        val c = b(t0 + 12 * 3_600 + 75 * 60, t0 + 14 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c), 0L)
        assertEquals(listOf(listOf(0), listOf(1)), groups.map { it.indices })
    }

    @Test
    fun threeFragmentNightYieldsTwoGaps() {
        val a = b(t0, t0 + 3_600)
        val c = b(t0 + 3_600 + 600, t0 + 2 * 3_600)
        val d = b(t0 + 2 * 3_600 + 900, t0 + 3 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c, d), 0L)
        assertEquals(listOf(listOf(0, 1, 2)), groups.map { it.indices })
        assertEquals(listOf(a.end to c.start, c.end to d.start), groups[0].gaps)
    }

    @Test
    fun overlappingFragmentStartsItsOwnGroup() {
        // Legacy semantics pinned: a negative gap (fragment starting inside the previous span) does
        // NOT bridge — `mainNightGroupIndices` has always required gap >= 0, and the refactor must
        // not change the pick. No seam is fabricated either.
        val a = b(t0, t0 + 4 * 3_600)
        val c = b(t0 + 3_600, t0 + 2 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c), 0L)
        assertEquals(listOf(listOf(0), listOf(1)), groups.map { it.indices })
        assertTrue(groups.all { it.gaps.isEmpty() })
    }

    @Test
    fun zeroGapBridgesWithoutSeam() {
        // Touching fragments (gap == 0) bridge, and no zero-length seam is emitted.
        val a = b(t0, t0 + 3_600)
        val c = b(t0 + 3_600, t0 + 2 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(a, c), 0L)
        assertEquals(listOf(listOf(0, 1)), groups.map { it.indices })
        assertTrue(groups[0].gaps.isEmpty())
    }

    @Test
    fun unsortedInputIndicesReferToOriginalPositions() {
        // Input order reversed: indices still point into the ORIGINAL list (late = 0, early = 1),
        // returned ascending within the group.
        val late = b(t0 + 2 * 3_600 + 16 * 60, t0 + 6 * 3_600)
        val early = b(t0 - 3_600, t0 + 2 * 3_600)
        val groups = SleepStageTotals.bridgedNightGroups(listOf(late, early), 0L)
        assertEquals(listOf(listOf(0, 1)), groups.map { it.indices })
        assertEquals(listOf(early.end to late.start), groups[0].gaps)
    }

    @Test
    fun emptyInputYieldsNoGroups() {
        assertTrue(SleepStageTotals.bridgedNightGroups(emptyList(), 0L).isEmpty())
    }

    /** The refactor guard: the main-night pick over the all-groups pass stays byte-identical for a
     *  biphasic night + nap day (MainNightConsistencyTest pins the rest of the behaviour). */
    @Test
    fun mainNightGroupIndicesUnchangedForBiphasicPlusNap() {
        val a = b(t0 - 3_600, t0 + 2 * 3_600)
        val c = b(t0 + 2 * 3_600 + 16 * 60, t0 + 6 * 3_600)
        val nap = b(t0 + 14 * 3_600, t0 + 15 * 3_600)
        assertEquals(listOf(0, 1), SleepStageTotals.mainNightGroupIndices(listOf(a, c, nap), 0L))
    }
}
