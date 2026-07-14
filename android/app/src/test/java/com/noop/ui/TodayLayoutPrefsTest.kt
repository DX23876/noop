package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic coverage for the Today section-order persistence (#today-layout): default order, encode/decode
 * round-trip, reorder, and the never-hide "append missing section" invariant. No Android context — these
 * are the pure functions the editor + Today render rely on. Mirrors the macOS TodayLayoutPrefs tests.
 */
class TodayLayoutPrefsTest {

    @Test
    fun emptyOrUnset_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(null))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder(""))
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("   "))
    }

    @Test
    fun encodeDecode_roundTripsAReorderedList() {
        val reordered = listOf(
            TodaySection.YOUR_CARDS, TodaySection.HEART_RATE, TodaySection.SYNTHESIS,
            TodaySection.KEY_METRICS, TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS,
        )
        val encoded = TodayLayoutPrefs.encode(reordered)
        assertEquals("yourCards,heartRate,synthesis,keyMetrics,workouts,recoveryVitals", encoded)
        assertEquals(reordered, TodayLayoutPrefs.decodeOrder(encoded))
    }

    @Test
    fun decode_appendsAnyKnownSectionMissingFromSavedOrder_neverHides() {
        // A saved order that omits WORKOUTS + YOUR_CARDS (e.g. saved by an older build) must still surface
        // them — appended in default-order position — so no section ever vanishes.
        val partial = "heartRate,synthesis,keyMetrics,recoveryVitals"
        val decoded = TodayLayoutPrefs.decodeOrder(partial)
        assertEquals(TodaySection.entries.size, decoded.size)
        assertEquals(
            listOf(
                TodaySection.HEART_RATE, TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                TodaySection.RECOVERY_VITALS,
                // appended (missing) in default order:
                TodaySection.WORKOUTS, TodaySection.YOUR_CARDS,
            ),
            decoded,
        )
    }

    @Test
    fun decode_dropsUnknownTokensAndCollapsesDuplicates() {
        val messy = "yourCards,BOGUS,yourCards,heartRate, ,heartRate"
        val decoded = TodayLayoutPrefs.decodeOrder(messy)
        // yourCards + heartRate resolved once each (first occurrence), then the remaining defaults appended.
        assertEquals(
            listOf(
                TodaySection.YOUR_CARDS, TodaySection.HEART_RATE,
                TodaySection.SYNTHESIS, TodaySection.KEY_METRICS,
                TodaySection.WORKOUTS, TodaySection.RECOVERY_VITALS,
            ),
            decoded,
        )
    }

    @Test
    fun allJunk_yieldsDefaultOrder() {
        assertEquals(TodaySection.defaultOrder, TodayLayoutPrefs.decodeOrder("nope,,zzz").let {
            // all-unknown tokens leave `seen` empty, then every default is appended → default order
            it
        })
    }

    @Test
    fun sectionRawKeysAreStableAndUnique() {
        val raws = TodaySection.entries.map { it.raw }
        assertEquals("raw keys must be unique (they're the persisted identity)", raws.size, raws.toSet().size)
        // Pin the exact wire strings — they cross the .noopbak boundary and must match macOS byte-for-byte.
        assertEquals(
            listOf("synthesis", "keyMetrics", "workouts", "heartRate", "recoveryVitals", "yourCards"),
            raws,
        )
    }
}
