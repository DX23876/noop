package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [HypnogramCoverage] — the ratio that tells a well-formed-looking stage timeline from one that
 * describes only part of the night it claims.
 *
 * BYTE-PARITY BY ORACLE, not by eye (CLAUDE.md). [swiftOracle] below is the VERBATIM stdout of the
 * Swift twin's arithmetic compiled standalone (`swiftc -O main.swift -o oracle && ./oracle`) over the
 * whole input space that matters: tiling, an interior hole, the measured 2026-08-18 night, the gate
 * boundary from both sides and exactly on it, overlap/overhang, every unmeasurable payload shape, and
 * degenerate spans. Reading the two implementations side by side would not catch a divergence in the
 * clamp, the null rules, or the boundary comparison; this does.
 *
 * Note the `gate-exact` row: 950/1000 prints as 0.94999999999999996 because that is the nearest double
 * to 0.95 — the SAME double the threshold literal denotes — so `< minCoverage` is false and the night is
 * not holed. Both platforms must agree on that, which is exactly why the row is pinned.
 */
class HypnogramCoverageTest {

    /** VERBATIM Swift stdout. Format: label|fraction (17 significant digits, or "null")|isHoled. */
    private val swiftOracle = """
        tiling|1|false
        two-seg tiling|1|false
        interior hole|0.5|true
        night-0818|0.23294509151414308|true
        gate-exact|0.94999999999999996|false
        gate-under|0.94899999999999995|true
        gate-over|0.95099999999999996|false
        overhang|1|false
        overlap|1|false
        zero-len segs|null|false
        neg-len seg|null|false
        empty-array|null|false
        blank|null|false
        nil|null|false
        not-json|null|false
        minute-dict|null|false
        zero-span|null|false
        neg-span|null|false
        mixed-nonobject|null|false
        array-with-null|null|false
        string-numbers|null|false
        bool-start|0.099|true
        timestamped-import|0.125|true
        hc-stage-min|null|false
        null-bound|null|false
    """.trimIndent()

    private fun seg(vararg r: Pair<Int, Int>): String =
        r.joinToString(",", "[", "]") { """{"start":${it.first},"end":${it.second},"stage":"deep"}""" }

    /** The same cases the Swift oracle enumerated, in the same order. */
    private val cases: List<Triple<String, String?, Double>> = listOf(
        Triple("tiling", seg(0 to 28800), 28800.0),
        Triple("two-seg tiling", seg(0 to 14400, 14400 to 28800), 28800.0),
        Triple("interior hole", seg(0 to 300, 900 to 1200), 1200.0),
        Triple("night-0818", seg(0 to 4200, 4200 to 8400), 601 * 60.0),
        Triple("gate-exact", seg(0 to 950), 1000.0),
        Triple("gate-under", seg(0 to 949), 1000.0),
        Triple("gate-over", seg(0 to 951), 1000.0),
        Triple("overhang", seg(0 to 1200), 600.0),
        Triple("overlap", seg(0 to 600, 300 to 900), 900.0),
        Triple("zero-len segs", seg(500 to 500, 600 to 600), 1000.0),
        Triple("neg-len seg", """[{"start":900,"end":300,"stage":"deep"}]""", 1000.0),
        Triple("empty-array", "[]", 1000.0),
        Triple("blank", "   ", 1000.0),
        Triple("nil", null, 1000.0),
        Triple("not-json", "not json", 1000.0),
        Triple("minute-dict", """{"light":300,"deep":100,"rem":80,"awake":40}""", 3600.0),
        Triple("zero-span", seg(0 to 300), 0.0),
        Triple("neg-span", seg(0 to 300), -1.0),
        // The four shapes on which the two readers originally DISAGREED, measured rather than read:
        // Swift's whole-array cast returns nil for a non-object element, where this side used to skip
        // it and measure the remainder (0.1, HOLED). A string start used to parse via optDouble and
        // count; Swift's `as? NSNumber` rejects it. A bool start converts on BOTH sides, because
        // JSONSerialization bridges it to NSNumber — the one case where "reject anything odd" would
        // have been the wrong alignment, and `{"start":0}` reporting `is Bool == true` under Foundation
        // is why a bool exclusion could not be used to express it.
        Triple("mixed-nonobject", """[{"start":0,"end":100,"stage":"deep"},5]""", 1000.0),
        Triple("array-with-null", """[{"start":0,"end":100,"stage":"deep"},null]""", 1000.0),
        Triple("string-numbers", """[{"start":"0","end":"100","stage":"deep"}]""", 1000.0),
        Triple("bool-start", """[{"start":true,"end":100,"stage":"deep"}]""", 1000.0),
        // A Xiaomi-shaped import: real timestamped segments that do not reach the session's own
        // bed/wake span. Unlike the timestamp-free imports this IS judged, which is the scope the
        // module doc now states outright.
        Triple("timestamped-import", seg(0 to 3600), 28800.0),
        // Health Connect's REAL shape. The oracle's `minute-dict` row is the throwing `{light,deep,...}`
        // object; HC emits an ARRAY of `{stage,min}` objects, which parses cleanly and reaches the loop.
        // It is the live producer shape this gate claims to be exempt from, so it is pinned rather than
        // argued: every element is an object (no bail), none carries bounds (every segment skipped),
        // covered stays 0, and zero cover is unmeasurable rather than bad.
        Triple("hc-stage-min", """[{"stage":"light","min":300},{"stage":"deep","min":100}]""", 3600.0),
        // A JSON null BOUND inside an otherwise well-formed object: the object itself is fine, so
        // neither side bails; both fail to read the bound and skip the segment.
        Triple("null-bound", """[{"start":null,"end":100,"stage":"deep"}]""", 1000.0),
    )

    @Test
    fun matchesTheSwiftOracleExactly() {
        val expected = swiftOracle.lines().map { it.trim() }.filter { it.isNotEmpty() }
        assertEquals("oracle row count must match the case list", cases.size, expected.size)
        for ((i, c) in cases.withIndex()) {
            val (label, json, span) = c
            val parts = expected[i].split("|")
            assertEquals("oracle row $i is for a different case", label, parts[0])

            val f = HypnogramCoverage.fraction(json, span)
            if (parts[1] == "null") {
                assertNull("$label: expected unmeasurable", f)
            } else {
                assertEquals("$label: fraction", parts[1].toDouble(), f!!, 0.0)
            }
            assertEquals("$label: isHoled", parts[2].toBoolean(),
                HypnogramCoverage.isHoled(json, span))
        }
    }

    /** nil is "not measured", never "measured badly" — the distinction every guard fails open on. */
    @Test
    fun unmeasurableIsNeverHoled() {
        for (payload in listOf(null, "", "   ", "[]", "not json",
            """{"light":300,"deep":100,"rem":80,"awake":40}""")) {
            assertNull(HypnogramCoverage.fraction(payload, 3600.0))
            assertFalse(HypnogramCoverage.isHoled(payload, 3600.0))
        }
    }

    @Test
    fun ratioOverloadMatchesSwift() {
        assertEquals(0.5, HypnogramCoverage.fraction(300.0, 600.0)!!, 0.0)
        assertEquals(1.0, HypnogramCoverage.fraction(600.0, 600.0)!!, 0.0)
        assertEquals(1.0, HypnogramCoverage.fraction(900.0, 600.0)!!, 0.0)  // clamped
        assertNull(HypnogramCoverage.fraction(300.0, 0.0))
        assertNull(HypnogramCoverage.fraction(0.0, 600.0))
    }

    /** The threshold itself is a stored cross-platform constant; a silent drift would move the gate. */
    @Test
    fun thresholdMatchesSwift() {
        assertEquals(0.95, HypnogramCoverage.minCoverage, 0.0)
    }

    /**
     * The measured night this whole change exists for (2026-08-18, Oura ring vs a paired WHOOP strap):
     * 140 minutes of segments across a 601-minute span, stored as 70 minutes of sleep where the strap
     * recorded 494.
     */
    @Test
    fun theMeasuredHoledNightIsFlagged() {
        val span = 601 * 60.0
        assertTrue(HypnogramCoverage.isHoled(seg(0 to 4200, 4200 to 8400), span))
        assertEquals(8400.0 / span, HypnogramCoverage.fraction(seg(0 to 4200, 4200 to 8400), span)!!, 1e-12)
    }

    /**
     * The ENGINE call site sums coverage off decoded segments, not off `stagesJson`, so the payload
     * shape rule that exempts timestamp-free imports at the merge does not run there. What actually
     * protects them is this: a group with no timestamped stages at all covers zero, and zero cover is
     * unmeasurable rather than bad. Holds only while a group is single-sourced — a group mixing a
     * staged fragment with a minute-dict one covers part of its total span and reads as holed.
     */
    @Test fun groupWithNoTimestampedStagesIsUnmeasurableNotHoled() {
        assertNull(HypnogramCoverage.fraction(0.0, 8 * 3600.0))
    }

    @Test fun mixedSourceGroupReadsAsHoled() {
        // 8 h fully-staged fragment + a 2 h minute-dict fragment that decodes to no segments.
        assertEquals(0.8, HypnogramCoverage.fraction(8 * 3600.0, 10 * 3600.0)!!, 1e-12)
        assertTrue(0.8 < HypnogramCoverage.minCoverage)
    }

    // ── the GROUP accumulation (what a night is actually judged on) ──────────────────────────────
    //
    // A night is not one row: the engine bridges the day's main-sleep fragments and accumulates over
    // ALL of them before testing the gate, and the Sleep screen's "Partly recorded" note asks the same
    // question of the same group. Pinned by oracle for the same reason as the per-payload rules above —
    // the accumulation has its own ways to drift (which fragments reach the denominator, whether an
    // unmeasurable payload contributes span, whether a partial sum survives a bail) and none of them
    // are visible by reading the two loops side by side.

    /**
     * VERBATIM stdout of the SHIPPED Swift `HypnogramCoverage` (linked as a package dependency and run,
     * not retyped), over the group cases below.
     * Format: label|groupFraction (17 significant digits, or "null")|isHoledGroup|floored percentage.
     *
     * `two-bridged-90-100` is the knife-edge row: 1900/2000 prints as 0.94999999999999996, the SAME
     * double the threshold literal denotes, so `< minCoverage` is false and the night is NOT flagged —
     * the group twin of the `gate-exact` row above, and the one a reimplementation is most likely to
     * get wrong in the other direction.
     */
    private val swiftGroupOracle = """
        single-full|1|false|100
        single-holed|0.25|true|25
        two-bridged-90-100|0.94999999999999996|false|95
        gap-excluded|1|false|100
        mixed-source|0.80000000000000004|true|80
        all-minute-dict|null|false|-
        health-connect|null|false|-
        non-object-bails|null|false|-
        non-object-in-group|0.5|true|50
        interior-hole|0.40000000000000002|true|40
        overlap-clamped|1|false|100
        empty-group|null|false|-
        zero-span|null|false|-
        night-20260828|0.93517534537725822|true|93
        boundary-0952|0.95199999999999996|false|95
        boundary-0948|0.94799999999999995|true|94
    """.trimIndent()

    private fun frag(json: String?, span: Double) = HypnogramCoverage.Fragment(json, span)

    @Test fun groupFractionMatchesTheSwiftOracle() {
        val minuteDict = """{"light":60,"deep":30,"rem":20,"awake":10}"""
        val hcArray = """[{"stage":"light","min":300},{"stage":"deep","min":100}]"""
        val nonObject = """[{"start":0,"end":100,"stage":"deep"},5]"""

        val cases: List<Pair<String, List<HypnogramCoverage.Fragment>>> = listOf(
            "single-full" to listOf(frag(seg(0 to 1000), 1000.0)),
            "single-holed" to listOf(frag(seg(0 to 300), 1200.0)),
            "two-bridged-90-100" to listOf(frag(seg(0 to 900), 1000.0), frag(seg(1200 to 2200), 1000.0)),
            "gap-excluded" to listOf(frag(seg(0 to 1000), 1000.0), frag(seg(5000 to 6000), 1000.0)),
            "mixed-source" to listOf(frag(seg(0 to 28800), 28800.0), frag(minuteDict, 7200.0)),
            "all-minute-dict" to listOf(frag(minuteDict, 14400.0), frag(null, 14400.0)),
            "health-connect" to listOf(frag(hcArray, 28800.0)),
            "non-object-bails" to listOf(frag(nonObject, 1000.0)),
            "non-object-in-group" to listOf(frag(seg(0 to 1000), 1000.0), frag(nonObject, 1000.0)),
            "interior-hole" to listOf(frag(seg(0 to 200, 800 to 1000), 1000.0)),
            "overlap-clamped" to listOf(frag(seg(0 to 1000, 0 to 1000), 1000.0)),
            "empty-group" to emptyList(),
            "zero-span" to listOf(frag(seg(0 to 100), 0.0)),
            "night-20260828" to listOf(frag(seg(0 to 26400), 28230.0)),   // 440.0 min of 470.5 min
            "boundary-0952" to listOf(frag(seg(0 to 95200), 100000.0)),
            "boundary-0948" to listOf(frag(seg(0 to 94800), 100000.0)),
        )

        val expected = swiftGroupOracle.lines().map { it.trim() }.filter { it.isNotEmpty() }
        assertEquals("oracle row count must match the case list", cases.size, expected.size)
        for ((i, c) in cases.withIndex()) {
            val (label, frags) = c
            val parts = expected[i].split("|")
            assertEquals("oracle row $i is for a different case", label, parts[0])

            val f = HypnogramCoverage.groupFraction(frags)
            if (parts[1] == "null") {
                assertNull("$label: expected unmeasurable", f)
            } else {
                assertEquals("$label", parts[1].toDouble(), f!!, 0.0)  // EXACT: same double, not close
            }
            assertEquals("$label: isHoledGroup", parts[2].toBoolean(), HypnogramCoverage.isHoledGroup(frags))
            // The percentage the "Partly recorded" note prints. FLOORED, never rounded: 94.8% must not
            // print as "95%" beside a badge raised because coverage fell below 95%.
            val pct = f?.let { kotlin.math.floor(it * 100.0).toInt().toString() } ?: "-"
            assertEquals("$label: printed percentage", parts[3], pct)
        }
    }

    /**
     * [HypnogramCoverage.coveredSeconds] is the summable half — 0, not null, for every payload the
     * ratio calls unmeasurable, so fragments add cleanly and the "is this even measurable" decision
     * stays in [HypnogramCoverage.fraction]. Verbatim Swift stdout.
     */
    @Test fun coveredSecondsMatchesTheSwiftOracle() {
        val oracle = """
            full|1000.0
            minuteDict|0.0
            hc|0.0
            nonObject|0.0
            empty|0.0
            blank|0.0
            nil|0.0
        """.trimIndent()
        val inputs = listOf(
            "full" to seg(0 to 1000),
            "minuteDict" to """{"light":60,"deep":30,"rem":20,"awake":10}""",
            "hc" to """[{"stage":"light","min":300},{"stage":"deep","min":100}]""",
            "nonObject" to """[{"start":0,"end":100,"stage":"deep"},5]""",
            "empty" to "[]",
            "blank" to "   ",
            "nil" to null,
        )
        val expected = oracle.lines().map { it.trim() }.filter { it.isNotEmpty() }
        assertEquals(inputs.size, expected.size)
        for ((i, p) in inputs.withIndex()) {
            val parts = expected[i].split("|")
            assertEquals("oracle row $i is for a different case", p.first, parts[0])
            assertEquals(p.first, parts[1].toDouble(), HypnogramCoverage.coveredSeconds(p.second), 0.0)
        }
    }

    /**
     * The inter-fragment GAP is not in the denominator. It belongs to no fragment's `[startTs, endTs)`,
     * and it is known-awake out-of-bed time (#777/#705) rather than time we failed to observe — folding
     * it in would report a correctly-recorded biphasic night as partly missing. Stated as its own test
     * because it is a claim about what the CALLER must pass, which an oracle over fragments cannot pin.
     */
    @Test fun groupDenominatorIsFragmentSpansNotTheWholeWindow() {
        val frags = listOf(frag(seg(0 to 1000), 1000.0), frag(seg(5000 to 6000), 1000.0))
        assertEquals(1.0, HypnogramCoverage.groupFraction(frags)!!, 0.0)
        assertFalse(HypnogramCoverage.isHoledGroup(frags))
    }
}
