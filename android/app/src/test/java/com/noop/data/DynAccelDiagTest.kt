package com.noop.data

import com.noop.protocol.DeviceFamily
import com.noop.protocol.extractHistoricalStreams
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * #520: `dynamic_acceleration@41` has been decoded on both platforms since the v18 layout was mapped, and
 * nothing has ever consumed it — so there is no evidence on whether it is a usable stillness signal or
 * redundant against the gravity deltas SleepStager already derives. These pin the diagnostic that collects
 * that evidence: a summary, not a stream, logged once per offload session.
 *
 * Kotlin twin of `DynAccelDiagTests.swift` — same vectors, same expected values, same log-line bytes.
 */
class DynAccelDiagTest {

    private val thr = 0.01   // mirrors DYN_ACCEL_STILL_THRESHOLD_G / SleepStager.gravityStillThresholdG

    /** Nothing arrived: derived values are null and the line is suppressed, so a WHOOP 4.0 stays quiet. */
    @Test
    fun emptyDiagIsSilent() {
        val d = DynAccelDiag()
        assertEquals(0, d.count)
        assertNull(d.mean)
        assertNull(d.stillFraction)
        assertNull(d.min)
        assertNull(d.max)
        assertNull(d.logLine(thr))
    }

    /** The real f32@41 values from the six captured v18 frames; three of the six fall under the cut. */
    @Test
    fun foldsRealOracleValues() {
        val d = DynAccelDiag()
        listOf(0.009160, 0.010708, 0.005963, 0.014449, 0.032788, 0.008421).forEach { d.add(it, thr) }
        assertEquals(6, d.count)
        assertEquals(3, d.still)
        assertEquals(0.5, d.stillFraction!!, 1e-12)
        assertEquals(0.005963, d.min!!, 1e-12)
        assertEquals(0.032788, d.max!!, 1e-12)
        assertEquals(0.081489 / 6, d.mean!!, 1e-9)
    }

    /** Strict `<`, matching the stager's own comparison — a value exactly at the cut is not still. */
    @Test
    fun thresholdIsExclusive() {
        val d = DynAccelDiag()
        d.add(thr, thr)
        assertEquals(0, d.still)
        d.add(thr - 1e-9, thr)
        assertEquals(1, d.still)
    }

    /** One NaN would otherwise poison mean/min/max for a whole session, so non-finite values are dropped. */
    @Test
    fun nonFiniteValuesAreIgnored() {
        val d = DynAccelDiag()
        d.add(0.02, thr)
        d.add(Double.NaN, thr)
        d.add(Double.POSITIVE_INFINITY, thr)
        assertEquals(1, d.count)
        assertEquals(0.02, d.mean!!, 1e-12)
        assertEquals(0.02, d.max!!, 1e-12)
    }

    /** A chunk is an arbitrary slice of an offload; the still-fraction only means anything once merged. */
    @Test
    fun mergeCombinesChunks() {
        val a = DynAccelDiag()
        a.add(0.004, thr)
        a.add(0.006, thr)
        val b = DynAccelDiag()
        b.add(0.500, thr)
        a.merge(b)
        assertEquals(3, a.count)
        assertEquals(2, a.still)
        assertEquals(0.004, a.min!!, 1e-12)
        assertEquals(0.500, a.max!!, 1e-12)
        assertEquals(0.510 / 3, a.mean!!, 1e-12)
    }

    /** A console-only batch is common mid-offload and must not disturb the accumulator. */
    @Test
    fun mergingEmptyIsNoOp() {
        val a = DynAccelDiag()
        a.add(0.02, thr)
        a.merge(DynAccelDiag())
        assertEquals(1, a.count)
        assertEquals(0.02, a.min!!, 1e-12)
        assertEquals(0.02, a.max!!, 1e-12)
    }

    /** The session accumulator starts empty, so merging into empty must adopt the other side's bounds. */
    @Test
    fun mergeIntoEmptyAdoptsBounds() {
        val a = DynAccelDiag()
        val b = DynAccelDiag()
        b.add(0.03, thr)
        b.add(0.07, thr)
        a.merge(b)
        assertEquals(b, a)
    }

    /** The byte-identical contract with Swift — pinned exactly, so a format drift on either side fails. */
    @Test
    fun logLineFormat() {
        val d = DynAccelDiag()
        d.add(0.004, thr)
        d.add(0.006, thr)
        d.add(2.310, thr)
        assertEquals(
            "Backfill: dynaccel n=3 still=67% mean=773mg range=4..2310mg " +
                "(thr 10mg) — diagnostic only, not stored or scored (#520)",
            d.logLine(thr),
        )
    }

    /**
     * The rounding trap. C (Swift) rounds ties half-to-EVEN, Java (Kotlin) rounds HALF_UP, so `%.3f` of
     * 0.0625 g is 0.062 on one platform and 0.063 on the other — and 0.0625 is exactly representable in the
     * f32 the strap sends. The line renders integers instead, rounded half-AWAY-from-zero, the one rule both
     * languages agree on for non-negative input. Same expectations as the Swift twin.
     */
    @Test
    fun tiesRoundAwayFromZeroNotPrintfStyle() {
        assertEquals(63, DynAccelDiag.mg(0.0625))
        assertEquals(14, DynAccelDiag.mg(0.0135))
        assertEquals(67, DynAccelDiag.pct(0.665))
        assertEquals(1, DynAccelDiag.pct(0.005))
    }

    /**
     * Twin of Swift `testExtractionPopulatesDiagFromARealFrame`. Proves the v18 path actually FOLDS the
     * field rather than merely exposing the type — the wiring, not the arithmetic. This matters more here
     * than on Swift: `android.yml` is disabled, so nothing in this file is compiled by default CI, and the
     * extraction hook is the piece most likely to be dropped by a future refactor.
     *
     * Reads the same captured worn frame from the shared oracle rather than pasting bytes, so this test and
     * the cross-platform oracle can never disagree about what the frame is. Its f32@41 is 0.009160 g.
     */
    @Test
    fun extractionPopulatesDiagFromARealFrame() {
        val stream = javaClass.classLoader!!.getResourceAsStream("decoder_oracle.json")
        assertNotNull("decoder_oracle.json missing from test classpath", stream)
        val oracle = JSONObject(stream!!.bufferedReader().use { it.readText() })
        val frames = oracle.getJSONArray("frames")
        var hex: String? = null
        for (i in 0 until frames.length()) {
            val f = frames.getJSONObject(i)
            if (f.getString("name") == "whoop5_v18_real_worn") hex = f.getString("hex")
        }
        assertNotNull("whoop5_v18_real_worn missing from the oracle", hex)

        val raw = hex!!
        val bytes = ByteArray(raw.length / 2) {
            ((raw[it * 2].digitToInt(16) shl 4) or raw[it * 2 + 1].digitToInt(16)).toByte()
        }
        val batch = extractHistoricalStreams(
            listOf(bytes),
            deviceClockRef = 0,
            wallClockRef = 0,
            family = DeviceFamily.WHOOP5,
        )
        assertEquals("the v18 path did not fold dynamic_acceleration", 1, batch.dynAccel.count)
        assertEquals(0.009160, batch.dynAccel.max!!, 1e-5)
        assertEquals("0.00916 g is under the 0.01 g stillness cut", 1, batch.dynAccel.still)
    }

    /**
     * The locale trap, asserted directly. The line is built from Int interpolation rather than
     * [String.format], so locale cannot reach it — this guards that property rather than a formatter
     * argument, and would fail immediately if anyone reintroduced `String.format` without Locale.ROOT.
     */
    @Test
    fun logLineIsLocaleIndependent() {
        val previous = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            val d = DynAccelDiag()
            d.add(0.004, thr)
            d.add(0.006, thr)
            d.add(2.310, thr)
            assertEquals(
                "Backfill: dynaccel n=3 still=67% mean=773mg range=4..2310mg " +
                    "(thr 10mg) — diagnostic only, not stored or scored (#520)",
                d.logLine(thr),
            )
        } finally {
            java.util.Locale.setDefault(previous)
        }
    }
}
