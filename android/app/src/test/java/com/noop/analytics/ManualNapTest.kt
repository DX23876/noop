package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Manually-added + editable NAPS — Android parity for iOS #508.
 *
 * A nap is stored as its OWN sleep session (never folded into main sleep). The persistence is iOS-parity:
 * `WhoopRepository.addManualNap` inserts a row under the computed source with `userEdited = true` and
 * `startTsAdjusted = null`, so the SAME recompute overlap guard that protects a hand-corrected night also
 * protects a manually-added nap and drops any re-detected overlapping session.
 *
 * Pure-function style (no Room/coroutines) so it runs under testFullDebugUnitTest. The overlap predicate
 * is the EXACT one used in IntelligenceEngine.analyzeRecent's `sleepKept` filter; the efficiency helper
 * mirrors WhoopRepository.sleepEfficiency byte-for-byte.
 */
class ManualNapTest {

    /** Re-encode a single-stage span to the on-device `[{start,end,stage}]` stagesJSON shape. */
    private fun stages(start: Long, end: Long, stage: String): String =
        AnalyticsEngine.encodeStages(listOf(StageSegment(start = start, end = end, stage = stage)))!!

    /** A manually-added nap as `addManualNap` writes it: own row, userEdited=true, no adjusted onset. */
    private fun manualNap(start: Long, end: Long) = SleepSession(
        deviceId = "my-whoop-noop",
        startTs = start,
        endTs = end,
        userEdited = true,
        startTsAdjusted = null,
    )

    private fun detected(start: Long, end: Long) = SleepSession(
        deviceId = "my-whoop-noop",
        startTs = start,
        endTs = end,
    )

    /** The EXACT overlap predicate from IntelligenceEngine.analyzeRecent (sleepKept). */
    private fun keptAfterGuard(
        detected: List<SleepSession>,
        edited: List<SleepSession>,
    ): List<SleepSession> {
        val editedWindows = edited.map { it.effectiveStartTs to it.endTs }
        return detected.filterNot { s ->
            editedWindows.any { (start, end) -> s.startTs < end && start < s.endTs }
        }
    }

    /** Mirror of WhoopRepository.sleepEfficiency — asleep fraction of a segment-array stagesJSON. */
    private fun sleepEfficiency(stagesJSON: String?): Double? {
        stagesJSON ?: return null
        val arr = runCatching { org.json.JSONArray(stagesJSON) }.getOrNull() ?: return null
        var asleep = 0.0
        var total = 0.0
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val s = o.optLong("start", -1L)
            val e = o.optLong("end", -1L)
            val stage = o.optString("stage")
            if (s < 0 || e <= s) continue
            val dur = (e - s).toDouble()
            total += dur
            if (stage != "wake" && stage != "awake") asleep += dur
        }
        return if (total > 0 && asleep > 0) asleep / total else null
    }

    // ── A manual nap is its OWN session, protected by the recompute guard ───────────────────────────

    @Test
    fun manualNapIsAFlaggedSeparateSession() {
        val nap = manualNap(start = 48_000, end = 49_800)
        assertTrue("a manually-added nap is flagged user-edited so the recompute guard keeps it", nap.userEdited)
        assertNull("a manual nap's onset IS the chosen onset (no detected twin)", nap.startTsAdjusted)
        assertEquals(48_000L, nap.effectiveStartTs)
    }

    @Test
    fun reDetectedSessionOverlappingAManualNapIsDropped() {
        // The user added a daytime nap [48000, 49800]. A later recompute re-detects sleep at a slightly
        // drifted window [48100, 49700] overlapping it — the guard must drop the twin (no duplicate).
        val nap = manualNap(start = 48_000, end = 49_800)
        val reDetected = detected(start = 48_100, end = 49_700)
        val kept = keptAfterGuard(detected = listOf(reDetected), edited = listOf(nap))
        assertTrue("a re-detected session overlapping a manual nap must be dropped", kept.isEmpty())
    }

    @Test
    fun manualNapNeverFoldedIntoMainSleep() {
        // Main sleep overnight + a daytime nap hours later. They are TWO separate windows: the guard keeps
        // the main sleep (no overlap with the nap) and the nap stays its own row — the nap is never folded
        // into main sleep, so the awake daytime gap between them is never mislabelled as light sleep.
        val mainSleep = detected(start = 1_000, end = 30_000)
        val nap = manualNap(start = 80_000, end = 82_400)
        val kept = keptAfterGuard(detected = listOf(mainSleep), edited = listOf(nap))
        assertEquals("main sleep is untouched by adding a separate nap", listOf(mainSleep), kept)
        // The two windows do not overlap — a nap is a distinct session.
        assertFalse(mainSleep.startTs < nap.endTs && nap.startTs < mainSleep.endTs)
    }

    // ── Editing a manual nap re-stages + STICKS across a recompute (no duplicate) ───────────────────

    @Test
    fun editedNapUsesEffectiveWindowAndIsProtected() {
        // Edit a detected nap [48600,50400] → corrected onset 48000 via startTsAdjusted, wake 51000. The
        // guard must test overlap against the EFFECTIVE window [48000,51000], dropping a re-detect inside it.
        val editedNap = SleepSession(
            deviceId = "my-whoop-noop", startTs = 48_600, endTs = 51_000,
            userEdited = true, startTsAdjusted = 48_000,
        )
        assertEquals(48_000L, editedNap.effectiveStartTs)
        val reDetected = detected(start = 48_200, end = 50_300)
        val kept = keptAfterGuard(detected = listOf(reDetected), edited = listOf(editedNap))
        assertTrue("overlap is tested against the EFFECTIVE edited nap window", kept.isEmpty())
    }

    // ── Efficiency seeded for a freshly-staged nap ──────────────────────────────────────────────────

    @Test
    fun napEfficiencyIsAsleepFraction() {
        // 30 min total, 20 min light asleep + 10 min wake → efficiency 2/3.
        val json = """[{"start":0,"end":1200,"stage":"light"},{"start":1200,"end":1800,"stage":"wake"}]"""
        val eff = sleepEfficiency(json)
        assertEquals(2.0 / 3.0, eff!!, 1e-9)
    }

    @Test
    fun wakeOnlyFallbackHasNullEfficiency() {
        // The fallback block (strap not dense yet) is a single wake segment — no asleep time → null.
        assertNull(sleepEfficiency(stages(50_000, 51_800, "wake")))
        assertNull(sleepEfficiency(null))
        assertNull(sleepEfficiency("[]"))
    }
}
