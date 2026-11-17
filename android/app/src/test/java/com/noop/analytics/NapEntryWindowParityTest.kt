package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The nap-entry window rules, against the Swift oracle (#49).
 *
 * The expected literal below is the VERBATIM stdout of `NapEntryWindowOracleTests` in
 * `Packages/StrandAnalytics` — printed by the Swift implementation over a spread of gaps, wake hours,
 * clock positions and UTC offsets, not written by hand. Reading the two implementations side by side does
 * not catch a band edge resolved one minute differently; this does. Note it guards this direction only: the
 * Swift tests in `NapEntryWindowTests` are what stop Swift drifting.
 */
class NapEntryWindowParityTest {

    private val day = 1_763_337_600L     // 2026-11-17 00:00 UTC

    private fun swiftName(v: SleepStageTotals.NapEntryVerdict): String = when (v) {
        SleepStageTotals.NapEntryVerdict.STANDS_AS_NAP -> "standsAsNap"
        SleepStageTotals.NapEntryVerdict.INSIDE_THE_NIGHT -> "insideTheNight"
        SleepStageTotals.NapEntryVerdict.FOLDED_INTO_THE_NIGHT -> "foldedIntoTheNight"
    }

    @Test
    fun `the Kotlin verdicts and suggestions match the Swift oracle`() {
        val expected = "insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,folde" +
        "dIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,27000/28800,34200/36000,504" +
        "00/52200,50400/52200,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,fol" +
        "dedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,32400/" +
        "34200,34200/36000,50400/52200,50400/52200,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,f" +
        "oldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsN" +
        "ap,standsAsNap,39600/41400,39600/41400,50400/52200,50400/52200,insideTheNight,foldedIntoTheNight" +
        ",foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsN" +
        "ap,standsAsNap,46800/48600,46800/48600,50400/52200,50400/52200,insideTheNight,foldedIntoTheNight" +
        ",foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsN" +
        "ap,standsAsNap,54000/55800,54000/55800,54000/55800,54000/55800,insideTheNight,foldedIntoTheNight" +
        ",foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight," +
        "standsAsNap,standsAsNap,standsAsNap,75600/77400,75600/77400,75600/77400,75600/77400,insideTheNig" +
        "ht,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNigh" +
        "t,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,27000/28800,34200/36000,46800/48600,468" +
        "00/48600,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNi" +
        "ght,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,32400/34200,34200/" +
        "36000,46800/48600,46800/48600,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoThe" +
        "Night,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,39600/41400,39600/" +
        "41400,46800/48600,46800/48600,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoThe" +
        "Night,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,46800/48600,46800/" +
        "48600,46800/48600,46800/48600,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoThe" +
        "Night,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap,54000/55800,54000/" +
        "55800,54000/55800,54000/55800,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoThe" +
        "Night,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsN" +
        "ap,75600/77400,75600/77400,75600/77400,75600/77400,insideTheNight,foldedIntoTheNight,foldedIntoT" +
        "heNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap," +
        "standsAsNap,standsAsNap,25200/27000,25200/27000,25200/27000,25200/27000,insideTheNight,foldedInt" +
        "oTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedInto" +
        "TheNight,standsAsNap,standsAsNap,standsAsNap,32400/34200,34200/36000,55800/57600,75600/77400,ins" +
        "ideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIn" +
        "toTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,39600/41400,39600/41400,55800/" +
        "57600,75600/77400,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,folded" +
        "IntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,46800/486" +
        "00,46800/48600,55800/57600,75600/77400,insideTheNight,foldedIntoTheNight,foldedIntoTheNight,fold" +
        "edIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap," +
        "standsAsNap,54000/55800,54000/55800,55800/57600,75600/77400,insideTheNight,foldedIntoTheNight,fo" +
        "ldedIntoTheNight,foldedIntoTheNight,standsAsNap,standsAsNap,standsAsNap,standsAsNap,standsAsNap," +
        "standsAsNap,75600/77400,75600/77400,75600/77400,75600/77400"
        val out = mutableListOf<String>()
        for (offset in listOf(0L, 3_600L, -7 * 3_600L)) {
            for (wakeHour in listOf(5, 7, 9, 11, 13, 19)) {
                val wake = day + wakeHour * 3_600L
                for (gapMin in listOf(-30, 0, 30, 59, 60, 61, 89, 90, 120, 480)) {
                    out.add(swiftName(
                        SleepStageTotals.napEntryVerdict(wake + gapMin * 60L, wake, offset)))
                }
                for (nowHour in listOf(8, 10, 16, 23)) {
                    val seed = SleepStageTotals.napEntrySeed(wake, offset, day + nowHour * 3_600L)
                    out.add("${seed.first - day}/${seed.last - day}")
                }
            }
        }
        assertEquals(expected, out.joinToString(","))
    }

    /** The verdict reads the same rule the grouping pass reads — asserted through the pass itself, which
     *  is the point of having one function rather than three copies of the test. */
    @Test
    fun `the verdict agrees with the grouping it predicts`() {
        val wake = day + 7 * 3_600L
        for (gapMin in listOf(0, 30, 59, 60, 89, 90, 120, 300)) {
            val start = wake + gapMin * 60L
            val blocks = listOf(
                SleepStageTotals.NightBlock(day - 3 * 3_600L, wake),
                SleepStageTotals.NightBlock(start, start + 1_800L))
            val merged = SleepStageTotals.bridgedNightGroups(blocks, 0L).size == 1
            val folded = SleepStageTotals.napEntryVerdict(start, wake, 0L) ==
                SleepStageTotals.NapEntryVerdict.FOLDED_INTO_THE_NIGHT
            assertEquals("gap $gapMin min", merged, folded)
        }
    }
}
