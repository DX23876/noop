package com.noop.analytics

import com.noop.data.SleepSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Durable sleep bed/wake editing — Android port of iOS PR #395.
 *
 * Covers the two pure mechanisms the recompute relies on:
 *   1. the recompute OVERLAP GUARD (IntelligenceEngine `cachedSleepKept`/`sleepKept`): a freshly
 *      detected session that time-overlaps a user-edited window is DROPPED before the upsert, so the
 *      re-detected night can't re-insert over the edit; a non-overlapping one is KEPT;
 *   2. [SleepStageTotals.dailyAggregateHonoringEdits]: the daily sleep aggregate substitutes an
 *      edited block's reshaped stages for its detected twin (matched on the stable detected startTs)
 *      so Rest + recovery score the corrected sleep.
 *
 * Pure-function style (no Room/coroutines) so it runs under testFullDebugUnitTest. The overlap
 * predicate is the EXACT one used in IntelligenceEngine.analyzeRecent's sleepKept filter.
 */
class SleepEditDurabilityTest {

    /** Re-encode a single-stage span to the on-device `[{start,end,stage}]` stagesJSON shape. */
    private fun stages(start: Long, end: Long, stage: String): String =
        AnalyticsEngine.encodeStages(listOf(StageSegment(start = start, end = end, stage = stage)))!!

    private fun computedSleep(
        start: Long,
        end: Long,
        userEdited: Boolean = false,
        startTsAdjusted: Long? = null,
    ) = SleepSession(
        deviceId = "my-whoop-noop",
        startTs = start,
        endTs = end,
        userEdited = userEdited,
        startTsAdjusted = startTsAdjusted,
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

    @Test
    fun overlappingDetectedSessionIsDropped() {
        // User edited a night spanning [1000, 5000]. The strap re-detected the same night at a slightly
        // drifted onset [1050, 4980] — it OVERLAPS the edited window, so it must be dropped.
        val edited = computedSleep(start = 1000, end = 5000, userEdited = true)
        val reDetected = computedSleep(start = 1050, end = 4980)

        val kept = keptAfterGuard(detected = listOf(reDetected), edited = listOf(edited))
        assertTrue("a detected session overlapping an edited window must be dropped", kept.isEmpty())
    }

    @Test
    fun nonOverlappingDetectedSessionIsKept() {
        // An edit on last night [1000, 5000] must NOT suppress a genuinely separate later night.
        val edited = computedSleep(start = 1000, end = 5000, userEdited = true)
        val otherNight = computedSleep(start = 90_000, end = 120_000) // hours later, no overlap

        val kept = keptAfterGuard(detected = listOf(otherNight), edited = listOf(edited))
        assertEquals("a non-overlapping detected session must be kept", listOf(otherNight), kept)
    }

    @Test
    fun guardUsesEffectiveStartForOverlap() {
        // The edit moved the bedtime EARLIER via startTsAdjusted (effectiveStartTs = 800, not the
        // detected startTs = 2000). A re-detect at [820, 1900] overlaps the EFFECTIVE window [800,5000]
        // but NOT the detected key 2000 — the guard must use effectiveStartTs and drop it.
        val edited = computedSleep(start = 2000, end = 5000, userEdited = true, startTsAdjusted = 800)
        assertEquals(800L, edited.effectiveStartTs)
        val reDetected = computedSleep(start = 820, end = 1900)

        val kept = keptAfterGuard(detected = listOf(reDetected), edited = listOf(edited))
        assertTrue("overlap must be tested against the EFFECTIVE edited window", kept.isEmpty())
    }

    @Test
    fun noEditsKeepsEverything() {
        val a = computedSleep(start = 1000, end = 5000)
        val b = computedSleep(start = 90_000, end = 120_000)
        val kept = keptAfterGuard(detected = listOf(a, b), edited = emptyList())
        assertEquals(listOf(a, b), kept)
    }

    // ── Durable DELETE tombstone (#33 / PR#46) ───────────────────────────────────────────────────
    //
    // A deleted night records a dismissedSleep(deviceId, startTs, endTs) marker; the recompute OR-s
    // those windows into the same overlap filter (skipWindows = editedWindows + dismissedWindows), so
    // a re-detected night that overlaps a tombstone is dropped and the delete stays durable. The helper
    // below is the EXACT skipWindows predicate from IntelligenceEngine.analyzeRecent's sleepKept filter.

    /** (startTs, endTs) tombstone span — the shape recorded by deleteSleepSession → dismissedSleeps. */
    private fun dismissedWindow(start: Long, end: Long): Pair<Long, Long> = start to end

    /** The EXACT sleepKept predicate AFTER the #33 change: edited + dismissed windows both suppress. */
    private fun keptAfterGuardWithDismissed(
        detected: List<SleepSession>,
        edited: List<SleepSession>,
        dismissed: List<Pair<Long, Long>>,
    ): List<SleepSession> {
        val editedWindows = edited.map { it.effectiveStartTs to it.endTs }
        val skipWindows = editedWindows + dismissed
        return detected.filterNot { s ->
            skipWindows.any { (start, end) -> s.startTs < end && start < s.endTs }
        }
    }

    @Test
    fun deletedNightStaysGoneAfterRecompute() {
        // User deleted last night [1000, 5000] → tombstone recorded. The next recompute re-detects the
        // very same night and must DROP it (delete→recompute→stays-gone), not re-upsert it.
        val tombstone = dismissedWindow(1000, 5000)
        val reDetected = computedSleep(start = 1000, end = 5000)

        val kept = keptAfterGuardWithDismissed(
            detected = listOf(reDetected),
            edited = emptyList(),
            dismissed = listOf(tombstone),
        )
        assertTrue("a re-detected night that was deleted must stay gone", kept.isEmpty())
    }

    @Test
    fun deletedNightStaysGoneWhenReDetectedOnsetDrifts() {
        // The re-detected onset drifts as more raw data arrives ([1050, 4980] vs the deleted [1000,5000]).
        // Overlap (not exact startTs) is why the tombstone still suppresses it — mirrors dismissedWorkout.
        val tombstone = dismissedWindow(1000, 5000)
        val reDetected = computedSleep(start = 1050, end = 4980)

        val kept = keptAfterGuardWithDismissed(
            detected = listOf(reDetected),
            edited = emptyList(),
            dismissed = listOf(tombstone),
        )
        assertTrue("a drifted re-detect of a deleted night must still be dropped", kept.isEmpty())
    }

    @Test
    fun deleteTombstoneDoesNotSuppressOtherNights() {
        // Deleting one night must not erase a genuinely separate later night.
        val tombstone = dismissedWindow(1000, 5000)
        val otherNight = computedSleep(start = 90_000, end = 120_000)

        val kept = keptAfterGuardWithDismissed(
            detected = listOf(otherNight),
            edited = emptyList(),
            dismissed = listOf(tombstone),
        )
        assertEquals("a non-overlapping night must survive an unrelated delete", listOf(otherNight), kept)
    }

    @Test
    fun editAndDeleteWindowsBothSuppress() {
        // Both guards compose: an edited night and a separately deleted night are each suppressed in one
        // pass, while an untouched third night is kept.
        val edited = computedSleep(start = 1000, end = 5000, userEdited = true)
        val editedReDetect = computedSleep(start = 1040, end = 4990)
        val deletedReDetect = computedSleep(start = 200_000, end = 230_000)
        val freshNight = computedSleep(start = 400_000, end = 430_000)
        val tombstone = dismissedWindow(200_000, 230_000)

        val kept = keptAfterGuardWithDismissed(
            detected = listOf(editedReDetect, deletedReDetect, freshNight),
            edited = listOf(edited),
            dismissed = listOf(tombstone),
        )
        assertEquals("only the untouched night survives", listOf(freshNight), kept)
    }

    // ── Daily-aggregate substitution (SleepStageTotals.dailyAggregateHonoringEdits) ──────────────

    @Test
    fun dailyAggregateSubstitutesEditedStagesForDetectedTwin() {
        // Detected twin: 6h light starting at 1000 (startTs is the match key). Edited: the user
        // extended/reshaped it to 8h asleep. The aggregate must reflect the EDITED stages.
        val detectedStart = 1000L
        val detected = listOf(detectedStart to stages(detectedStart, detectedStart + 6 * 3600, "light"))
        val edited = mapOf(detectedStart to stages(detectedStart, detectedStart + 8 * 3600, "deep"))

        val r = SleepStageTotals.dailyAggregateHonoringEdits(detected, edited)
        assertNotNull(r)
        assertTrue("an edit on a detected twin must report editApplied", r!!.editApplied)
        // 8h of deep == 480 min asleep, 0 awake → efficiency 1.0; deep=480, light=0.
        assertEquals(480.0, r.sleep.totalSleepMin, 1e-6)
        assertEquals(480.0, r.sleep.deepMin, 1e-6)
        assertEquals(0.0, r.sleep.lightMin, 1e-6)
        assertEquals(1.0, r.sleep.efficiency, 1e-6)
    }

    @Test
    fun dailyAggregateUnchangedWhenNoEditMatches() {
        // Detected twin at 1000; the edit is keyed on a DIFFERENT startTs (2000) → no substitution.
        val detected = listOf(1000L to stages(1000, 1000 + 6 * 3600, "light"))
        val edited = mapOf(2000L to stages(2000, 2000 + 8 * 3600, "deep"))

        val r = SleepStageTotals.dailyAggregateHonoringEdits(detected, edited)
        assertNotNull(r)
        assertFalse("a non-matching edit must NOT set editApplied", r!!.editApplied)
        // Falls back to the 6h detected light block.
        assertEquals(360.0, r.sleep.totalSleepMin, 1e-6)
        assertEquals(360.0, r.sleep.lightMin, 1e-6)
    }

    @Test
    fun editedToNullStagesFallsBackToDetected() {
        // An edit that reshaped to null stages must NOT drop the block (which would collapse the
        // night's sleep total) — it falls back to the detected stages and does NOT set editApplied.
        val detected = listOf(1000L to stages(1000, 1000 + 6 * 3600, "light"))
        val edited = mapOf<Long, String?>(1000L to null)

        val r = SleepStageTotals.dailyAggregateHonoringEdits(detected, edited)
        assertNotNull(r)
        assertFalse("an edit reshaped to null must fall back, not substitute", r!!.editApplied)
        assertEquals(360.0, r.sleep.totalSleepMin, 1e-6)
    }

    @Test
    fun emptyDetectedDecodesToNull() {
        assertNull(SleepStageTotals.dailyAggregateHonoringEdits(emptyList(), emptyMap()))
    }

    // ── minutes() decoder handles both Android stagesJSON shapes ─────────────────────────────────

    @Test
    fun minutesParsesSegmentSecondsArray() {
        val m = SleepStageTotals.minutes(stages(0, 3600, "deep")) // 1h deep
        assertNotNull(m)
        assertEquals(60.0, m!!.deep, 1e-6)
        assertEquals(60.0, m.asleep, 1e-6)
    }

    @Test
    fun minutesParsesImportedMinuteArray() {
        // Imported WhoopCsvImporter shape: [{stage,min}].
        val json = """[{"stage":"light","min":210.0},{"stage":"deep","min":80.0},{"stage":"awake","min":25.0}]"""
        val m = SleepStageTotals.minutes(json)
        assertNotNull(m)
        assertEquals(210.0, m!!.light, 1e-6)
        assertEquals(80.0, m.deep, 1e-6)
        assertEquals(25.0, m.awake, 1e-6)
        assertEquals(290.0, m.asleep, 1e-6)
        assertEquals(315.0, m.inBed, 1e-6)
    }

    @Test
    fun minutesReturnsNullForGarbage() {
        assertNull(SleepStageTotals.minutes(null))
        assertNull(SleepStageTotals.minutes("not json"))
        assertNull(SleepStageTotals.minutes("[]"))
    }
}
