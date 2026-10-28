package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic coverage for the Today section-order persistence (#today-layout): default order, encode/decode
 * round-trip, reorder, and the never-hide "insert missing section at its default position" invariant. No
 * Android context — these are the pure functions the editor + Today render rely on. Mirrors the macOS
 * TodayLayoutPrefs tests.
 */
class TodayLayoutPrefsTest {

    @Test
    fun emptyOrUnset_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(null))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(""))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("   "))
    }

    /** `coach` sits mid-list: it leads defaultOrder, so a decoder re-inserting it at its default would still pass elsewhere. */
    @Test
    fun encodeDecode_roundTripsAReorderedList() {
        val reordered = listOf(
                TodaySection.ENERGY, TodaySection.HEART_RATE, TodaySection.GOALS, TodaySection.HERO, TodaySection.YOUR_CARDS, TodaySection.COACH, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.TRAINING_LOAD, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            )
        val encoded = TodayLayoutPrefs.encode(reordered)
        assertEquals(
            "energy,heartRate,goals,hero,yourCards,coach,liveSession,synthesis,keyMetrics,trainingLoad,workouts,recoveryVitals,menstrualCycle,journal,dataSources,addedCards",
            encoded,
        )
        assertEquals(reordered, TodayLayoutPrefs.decodeOrder(encoded))
    }

    /** The expectations are the Apple `TodayLayoutPrefsTests` ones, so an order back-fills the same on both. */
    @Test
    fun decode_savedOrderFromFirstCut_insertsNewerSectionsAtTheirDefaultPosition() {
        assertEquals(
            listOf(
                TodaySection.COACH, TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.GOALS, TodaySection.KEY_METRICS, TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.HEART_RATE, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.decodeOrder("synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards"),
        )
    }

    @Test
    fun decode_insertsAnyMissingSectionAtItsDefaultPositionRelativeToSaved_neverHides() {
        assertEquals(
            listOf(
                TodaySection.COACH, TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.GOALS, TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.HEART_RATE, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.decodeOrder("heartRate,synthesis,keyMetrics,recoveryVitals"),
        )
    }

    @Test
    fun decode_dropsUnknownTokensAndCollapsesDuplicates() {
        assertEquals(
            listOf(
                TodaySection.COACH, TodaySection.HERO, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.GOALS, TodaySection.KEY_METRICS, TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.YOUR_CARDS, TodaySection.HEART_RATE, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.decodeOrder("yourCards,BOGUS,yourCards,heartRate, ,heartRate"),
        )
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("nope,,zzz"))
    }

    @Test
    fun hiddenSections_areExplicitReversibleAndDeduplicated() {
        val hidden = TodayLayoutPrefs.decodeHidden("workouts,BOGUS,workouts,journal")
        assertEquals(listOf(TodaySection.WORKOUTS, TodaySection.JOURNAL), hidden)
        assertEquals("workouts,journal", TodayLayoutPrefs.encodeHidden(hidden))
    }

    @Test
    fun visibleOrder_filtersHiddenWithoutChangingSavedOrder() {
        val order = "heartRate,hero,yourCards,liveSession,synthesis,keyMetrics,workouts,recoveryVitals,journal"
        assertEquals(
            listOf(
                TodaySection.COACH, TodaySection.GOALS, TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.HEART_RATE, TodaySection.YOUR_CARDS, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.RECOVERY_VITALS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.visibleOrder(order, "hero,workouts"),
        )
        assertEquals(
            listOf(
                TodaySection.COACH, TodaySection.GOALS, TodaySection.TRAINING_LOAD, TodaySection.ENERGY, TodaySection.HEART_RATE, TodaySection.HERO, TodaySection.YOUR_CARDS, TodaySection.LIVE_SESSION, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS, TodaySection.MENSTRUAL_CYCLE, TodaySection.JOURNAL, TodaySection.DATA_SOURCES, TodaySection.ADDED_CARDS,
            ),
            TodayLayoutPrefs.decodeOrder(order),
        )
    }

    @Test
    fun newOrPreviouslyMissingSections_defaultToVisible() {
        val visible = TodayLayoutPrefs.visibleOrder(
            "synthesis,keyMetrics,workouts,heartRate,recoveryVitals,yourCards",
            "workouts",
        )
        assertEquals(true, TodaySection.JOURNAL in visible)
    }

    /** defaultOrder must cover EVERY entry: the never-hide merge sorts by default index, so an entry
     *  missing from the default order could otherwise be dropped or mis-sorted. Twin of the Swift test. */
    @Test
    fun defaultOrderCoversEveryEntry() {
        assertEquals(TodaySection.entries.toSet(), TodaySection.defaultOrder.toSet())
        assertEquals(TodaySection.entries.size, TodaySection.defaultOrder.size)
    }

    @Test
    fun sectionRawKeysAreStableAndUnique() {
        val raws = TodaySection.entries.map { it.raw }
        assertEquals("raw keys must be unique (they're the persisted identity)", raws.size, raws.toSet().size)
        // Pin the exact wire strings: the Apple ones, so a layout saved on either platform reads the same.
        assertEquals(
            listOf(
                "coach", "hero", "liveSession", "synthesis", "goals", "keyMetrics", "trainingLoad", "energy", "workouts",
                "heartRate", "recoveryVitals", "yourCards", "menstrualCycle", "journal", "dataSources", "addedCards",
            ),
            raws,
        )
    }
}
