package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure planning logic for the Health Connect export (HR decimation/windowing/chunking, sleep
 * AWAKE/SLEEPING mapping). All offline-on-JVM; the SDK glue in [HealthConnectWriter] is the thin
 * untestable layer. (Daily steps/active-energy aggregates were removed with the steps/kcal
 * write-back — see HealthConnectWriter.)
 */
class HealthExportPlanTest {

    // ---- Heart-rate series tests ----

    private fun hr(ts: Long, bpm: Int) = HealthExportPlan.HrPoint(ts, bpm)

    @Test fun heartRate_emptyInputLeavesFrontierUnchanged() {
        val plan = HealthExportPlan.heartRate(emptyList(), emptyList(), frontierSec = 500L)
        assertTrue(plan.chunks.isEmpty())
        assertEquals(500L, plan.newFrontierSec)
    }

    @Test fun heartRate_ignoresSamplesAtOrBelowFrontier() {
        val samples = listOf(hr(100, 60), hr(200, 61), hr(300, 62))
        val plan = HealthExportPlan.heartRate(samples, emptyList(), frontierSec = 200L,
            decimateSec = 1, chunkSec = 3600, maxSamplesPerChunk = 1000)
        val tss = plan.chunks.flatMap { it.points }.map { it.tsSec }
        assertEquals(listOf(300L), tss)
        assertEquals(300L, plan.newFrontierSec)
    }

    @Test fun heartRate_decimatesOutsideWindowsToOnePerInterval() {
        // 1 Hz for 0..120s, no windows, decimate to 30s -> keep 0,30,60,90,120
        val samples = (0..120L).map { hr(it, 60) }
        val plan = HealthExportPlan.heartRate(samples, emptyList(), frontierSec = -1L,
            decimateSec = 30, chunkSec = 3600, maxSamplesPerChunk = 1000)
        val tss = plan.chunks.flatMap { it.points }.map { it.tsSec }
        assertEquals(listOf(0L, 30L, 60L, 90L, 120L), tss)
        assertEquals(120L, plan.newFrontierSec) // frontier advances past ALL seen samples
    }

    @Test fun heartRate_keepsFullResolutionInsideAWindow() {
        val samples = (0..120L).map { hr(it, 70) }
        val window = HealthExportPlan.Window(startSec = 40, endSec = 60) // 21 samples kept in full
        val plan = HealthExportPlan.heartRate(samples, listOf(window), frontierSec = -1L,
            decimateSec = 30, chunkSec = 3600, maxSamplesPerChunk = 1000)
        val tss = plan.chunks.flatMap { it.points }.map { it.tsSec }
        // Every second 40..60 present at full resolution...
        assertTrue((40L..60L).all { it in tss })
        // ...while samples OUTSIDE the window are decimated to one per 30s (0, 30, 90, 120).
        assertEquals(listOf(0L, 30L, 90L, 120L), tss.filter { it !in 40L..60L })
    }

    @Test fun heartRate_frontierAdvancesPastDecimatedTailSamples() {
        // 0 is kept; 5 is decimated away (within 30s of 0). The frontier must still advance to 5
        // so the dropped tail sample is never reconsidered on the next run.
        val plan = HealthExportPlan.heartRate(
            listOf(hr(0, 60), hr(5, 61)), emptyList(), frontierSec = -1L,
            decimateSec = 30, chunkSec = 3600, maxSamplesPerChunk = 1000)
        val tss = plan.chunks.flatMap { it.points }.map { it.tsSec }
        assertEquals(listOf(0L), tss)          // only the first sample exported
        assertEquals(5L, plan.newFrontierSec)  // frontier past the decimated-away tail
    }

    @Test fun heartRate_chunksByTimeSpan() {
        val samples = listOf(hr(0, 60), hr(10, 60), hr(4000, 60)) // gap > 3600s
        val plan = HealthExportPlan.heartRate(samples, listOf(HealthExportPlan.Window(0, 5000)),
            frontierSec = -1L, decimateSec = 1, chunkSec = 3600, maxSamplesPerChunk = 1000)
        assertEquals(2, plan.chunks.size)
        assertEquals("noop-hr-0", plan.chunks[0].clientId)
        assertEquals("noop-hr-4000", plan.chunks[1].clientId)
    }

    @Test fun heartRate_chunksBySampleCount() {
        val samples = (0 until 5L).map { hr(it, 60) }
        val plan = HealthExportPlan.heartRate(samples, listOf(HealthExportPlan.Window(0, 10)),
            frontierSec = -1L, decimateSec = 1, chunkSec = 3600, maxSamplesPerChunk = 2)
        assertEquals(3, plan.chunks.size) // 2 + 2 + 1
    }

    // ---- Sleep session tests ----

    @Test fun sleep_excludesUnfinalizedSessions() {
        val sessions = listOf(HealthExportPlan.SleepInput(startTs = 100, endTs = 900, stagesJSON = null))
        val out = HealthExportPlan.sleepSessions(sessions, nowSec = 500L) // ends in the future
        assertTrue(out.isEmpty())
    }

    @Test fun sleep_emitsFinalizedSessionWithClientId() {
        val sessions = listOf(HealthExportPlan.SleepInput(100, 900, null))
        val out = HealthExportPlan.sleepSessions(sessions, nowSec = 1000L)
        assertEquals(1, out.size)
        assertEquals("noop-sleep-100", out[0].clientId)
        assertEquals(100L, out[0].startSec)
        assertEquals(900L, out[0].endSec)
        assertTrue(out[0].stages.isEmpty()) // null stagesJSON -> session bounds only
    }

    @Test fun sleep_mapsWakeVsAsleepAndCoalesces() {
        val json = """
            [{"start":100,"end":200,"stage":"light"},
             {"start":200,"end":300,"stage":"deep"},
             {"start":300,"end":400,"stage":"wake"},
             {"start":400,"end":500,"stage":"awake"},
             {"start":500,"end":600,"stage":"rem"}]
        """.trimIndent()
        val out = HealthExportPlan.sleepSessions(
            listOf(HealthExportPlan.SleepInput(100, 600, json)), nowSec = 1000L)
        val stages = out[0].stages
        // light+deep coalesce -> asleep[100,300); wake+awake coalesce -> awake[300,500); rem -> asleep[500,600)
        assertEquals(3, stages.size)
        assertEquals(true, stages[0].asleep); assertEquals(100L, stages[0].startSec); assertEquals(300L, stages[0].endSec)
        assertEquals(false, stages[1].asleep); assertEquals(300L, stages[1].startSec); assertEquals(500L, stages[1].endSec)
        assertEquals(true, stages[2].asleep); assertEquals(500L, stages[2].startSec); assertEquals(600L, stages[2].endSec)
    }

    @Test fun sleep_malformedJsonYieldsNoStagesButKeepsSession() {
        val out = HealthExportPlan.sleepSessions(
            listOf(HealthExportPlan.SleepInput(100, 900, "not json")), nowSec = 1000L)
        assertEquals(1, out.size)
        assertTrue(out[0].stages.isEmpty())
    }

    @Test fun sleep_includesSessionEndingExactlyAtNow() {
        // endTs == nowSec is finalized (the session has ended); locks in the boundary contract.
        val out = HealthExportPlan.sleepSessions(
            listOf(HealthExportPlan.SleepInput(100, 1000, null)), nowSec = 1000L)
        assertEquals(1, out.size)
    }

    @Test fun sleep_skipsSegmentsWithNoStageLabel() {
        // A segment with valid bounds but no "stage" field is dropped (not fabricated as asleep),
        // leaving a gap; the surrounding labelled segments survive.
        val json = """
            [{"start":100,"end":200,"stage":"light"},
             {"start":200,"end":300},
             {"start":300,"end":400,"stage":"deep"}]
        """.trimIndent()
        val out = HealthExportPlan.sleepSessions(
            listOf(HealthExportPlan.SleepInput(100, 400, json)), nowSec = 1000L)
        val stages = out[0].stages
        // light[100,200) and deep[300,400) both asleep but NOT contiguous (gap 200..300) -> 2 segments.
        assertEquals(2, stages.size)
        assertEquals(100L, stages[0].startSec); assertEquals(200L, stages[0].endSec)
        assertEquals(300L, stages[1].startSec); assertEquals(400L, stages[1].endSec)
    }

    @Test fun sleep_skipsInvertedOrZeroLengthSession() {
        val out = HealthExportPlan.sleepSessions(
            listOf(
                HealthExportPlan.SleepInput(500, 500, null), // zero-length
                HealthExportPlan.SleepInput(900, 400, null), // inverted
            ),
            nowSec = 10_000L,
        )
        assertTrue(out.isEmpty())
    }
}
