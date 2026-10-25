package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #1001 — the single Effort figure every read-out on Today resolves through. Twin of the Swift
 * `EffectiveEffortTests`; the same cases in the same order, because the two platforms must resolve
 * Effort identically.
 *
 * The bug: Effort was resolved independently in three places. Only the hero ring knew about the live
 * in-progress recompute; the Key Metrics tile and the HR chart's edge badge read the stored daily row,
 * which is rewritten only when the heavy daily pass runs. On a morning with a real HR climb the ring
 * showed 2.3 while the other two still showed 0.5.
 *
 * These pin the resolution rule itself, and in particular the MAX — which is not a tie-break but the
 * never-drop floor from #489/#506, where a sparse-HR live under-read replaced a real 38.3 with 0.
 */
class EffectiveEffortTest {

    /** The reported case: a live value ahead of a stale row wins, so every read-out moves together. */
    @Test fun liveAheadOfAStaleRowWins() {
        assertEquals(2.3, StrainScorer.effectiveEffort(live = 2.3, stored = 0.5)!!, 1e-9)
    }

    /** The #489/#506 floor: a live UNDER-read must never pull a read-out below what today already earned. */
    @Test fun aStoredValueFloorsALiveUnderRead() {
        assertEquals(38.3, StrainScorer.effectiveEffort(live = 0.0, stored = 38.3)!!, 1e-9)
    }

    /** Past days carry no live value and use the row unchanged. */
    @Test fun noLiveValueUsesTheStoredRow() {
        assertEquals(12.5, StrainScorer.effectiveEffort(live = null, stored = 12.5)!!, 1e-9)
    }

    /** Before the day has enough HR to score there is no row yet, so the live value stands alone. */
    @Test fun noStoredRowUsesTheLiveValue() {
        assertEquals(4.0, StrainScorer.effectiveEffort(live = 4.0, stored = null)!!, 1e-9)
    }

    /** Neither source is "No Data" — the read-outs must not invent a zero. */
    @Test fun neitherSourceIsNull() {
        assertNull(StrainScorer.effectiveEffort(live = null, stored = null))
    }

    /** A genuine zero is a value, not an absence: a still day scores 0 and must render as 0, not "—". */
    @Test fun aGenuineZeroIsKept() {
        assertEquals(0.0, StrainScorer.effectiveEffort(live = 0.0, stored = 0.0)!!, 1e-9)
        assertEquals(0.0, StrainScorer.effectiveEffort(live = null, stored = 0.0)!!, 1e-9)
    }

    /** Equal sources are stable — resolving twice cannot make a read-out flicker. */
    @Test fun equalSourcesResolveToThatValue() {
        assertEquals(7.25, StrainScorer.effectiveEffort(live = 7.25, stored = 7.25)!!, 1e-9)
    }

    /** #37: when both sources are zero, every sign pairing has the canonical positive-zero bits. */
    @Test fun bothPresentZerosCanonicalizePositiveZero() {
        val cases = listOf(
            Triple("positive/positive", 0.0, 0.0),
            Triple("positive/negative", 0.0, -0.0),
            Triple("negative/positive", -0.0, 0.0),
            Triple("negative/negative", -0.0, -0.0),
        )

        for ((label, live, stored) in cases) {
            val result = StrainScorer.effectiveEffort(live = live, stored = stored)!!
            assertEquals(label, 0.0.toRawBits(), result.toRawBits())
        }
    }

    /** A missing source is passthrough, including its exact signed-zero and NaN representation. */
    @Test fun singleSourcePassesThroughBitForBit() {
        val values = listOf(
            0.0,
            -0.0,
            7.25,
            -7.25,
            Double.POSITIVE_INFINITY,
            Double.NEGATIVE_INFINITY,
            Double.fromBits(0x7ff8_0000_0000_0042L),
        )

        for (value in values) {
            assertEquals(value.toRawBits(),
                StrainScorer.effectiveEffort(live = value, stored = null)!!.toRawBits())
            assertEquals(value.toRawBits(),
                StrainScorer.effectiveEffort(live = null, stored = value)!!.toRawBits())
        }
    }

    /** The zero canonicalization must not broaden into a replacement for Kotlin's MAX semantics. */
    @Test fun bothPresentNonzeroAndNaNBehaviorIsUnchanged() {
        val nanA = Double.fromBits(0x7ff8_0000_0000_0042L)
        val nanB = Double.fromBits(0x7ff8_0000_0000_0024L)
        val cases = listOf(
            Triple(2.3, 0.5, 2.3),
            Triple(7.25, 7.25, 7.25),
            Triple(Double.POSITIVE_INFINITY, 12.0, Double.POSITIVE_INFINITY),
            Triple(12.0, Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY),
            Triple(Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.NEGATIVE_INFINITY),
            Triple(nanA, 1.0, nanA),
            Triple(1.0, nanA, nanA),
            Triple(nanA, nanB, nanA),
            Triple(nanB, nanA, nanB),
        )

        for ((live, stored, expected) in cases) {
            val result = StrainScorer.effectiveEffort(live = live, stored = stored)!!
            assertEquals(expected.toRawBits(), result.toRawBits())
        }
    }
}
