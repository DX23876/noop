package com.noop.ingest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * Pins the WHOOP export-import day-keying for the sleeps.csv → DailyMetric fold.
 *
 * Regression for the Android-only export day-shift bug: the non-nap sleep fold used to key its
 * DailyMetric off sleep ONSET, but onset sits on the PREVIOUS calendar evening while the matching
 * physiological_cycles row is keyed off cycle_start_time = the WAKE day. Because mergeDaily groups
 * by day-string, the two rows landed on different days — the night's sleep architecture went one
 * day early and the night was split across two daily rows. parseSleeps now keys the fold off
 * wake_onset first (matching macOS, the AppleHealth importer, and the sleep-session merge), so the
 * sleep row and the cycle row share a day and mergeDaily collapses them into ONE daily row.
 */
class WhoopCsvImporterTest {

    private val device = "my-whoop"

    private fun sleepParse(csv: String): WhoopCsvImporter.SleepParse =
        WhoopCsvImporter.parseSleeps(CsvTable.fromData(csv.trimIndent().toByteArray()), device)

    private fun cycles(csv: String) =
        WhoopCsvImporter.parseCycles(CsvTable.fromData(csv.trimIndent().toByteArray()), device)

    /**
     * A main sleep that begins 2024-01-01 23:15 and ends 2024-01-02 06:30 at UTC+01:00 must fold
     * onto the WAKE day 2024-01-02 (not the onset day 2024-01-01), and MERGE with the cycle row —
     * also keyed off the wake day — into a single daily row.
     */
    @Test
    fun mainSleepFoldsToWakeDayAndMergesWithCycleRow() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min),Light sleep duration (min),Deep (SWS) duration (min),REM duration (min)
            2024-01-02 06:30:00,UTC+01:00,2024-01-01 23:15:00,2024-01-02 06:30:00,false,420,210,90,120
            """
        )

        // The folded daily row is attributed to the WAKE day, not the onset evening.
        assertEquals(1, sleeps.daily.size)
        val sleepDay = sleeps.daily.single()
        assertEquals("2024-01-02", sleepDay.day)
        assertEquals(420.0, sleepDay.totalSleepMin!!, 1e-9)

        // The physiological_cycles row for the same night is keyed off cycle_start_time = wake day.
        val cycleRows = cycles(
            """
            Cycle start time,Cycle end time,Cycle timezone,Recovery score %,Resting heart rate (bpm),Day strain
            2024-01-02 06:30:00,2024-01-03 06:00:00,UTC+01:00,66,52,8.4
            """
        )
        assertEquals(1, cycleRows.size)
        assertEquals("2024-01-02", cycleRows.single().day)

        // mergeDaily collapses the cycle + sleep rows for 2024-01-02 into ONE daily row that carries
        // both the cycle fields (recovery / RHR) and the sleep architecture (total / deep / REM).
        val merged = WhoopCsvImporter.mergeDaily(cycleRows, sleeps.daily)
        assertEquals("the night must not be split across two daily rows", 1, merged.size)
        val day = merged.single()
        assertEquals("2024-01-02", day.day)
        assertEquals(66.0, day.recovery!!, 1e-9)          // from the cycle row
        assertEquals(52, day.restingHr)                   // from the cycle row
        assertEquals(420.0, day.totalSleepMin!!, 1e-9)    // from the sleep row
        assertEquals(90.0, day.deepMin!!, 1e-9)           // from the sleep row
        assertEquals(120.0, day.remMin!!, 1e-9)           // from the sleep row
    }

    /** Naps are excluded from the daily fold entirely (no spurious daily row). */
    @Test
    fun napsAreNotFoldedIntoDaily() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min)
            2024-01-02 06:30:00,UTC+01:00,2024-01-02 13:00:00,2024-01-02 13:45:00,true,45
            """
        )
        assertEquals(0, sleeps.daily.size)
        // The nap still produces a SleepSession (keyed off its own onset).
        assertEquals(1, sleeps.sessions.size)
        assertNotNull(sleeps.sessions.single())
    }

    /** When wake_onset is missing, the fold falls back to cycle_start, then onset. */
    @Test
    fun missingWakeOnsetFallsBackToCycleStart() {
        val sleeps = sleepParse(
            """
            Cycle start time,Cycle timezone,Sleep onset,Wake onset,Nap,Asleep duration (min)
            2024-01-02 06:30:00,UTC+01:00,2024-01-01 23:15:00,,false,420
            """
        )
        assertEquals(1, sleeps.daily.size)
        // cycle_start_time = wake day, so the fold still lands on 2024-01-02.
        assertEquals("2024-01-02", sleeps.daily.single().day)
    }
}
