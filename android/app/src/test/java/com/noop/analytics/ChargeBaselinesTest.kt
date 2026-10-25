package com.noop.analytics

import com.noop.data.DailyMetric
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which nights the Charge baselines are folded from (#2525).
 *
 * The defect these pin: the imported vendor history was folded in full while the wearer's own nights entered
 * only from the scan window, so the import kept about a third of the weight however long NOOP had been worn.
 * Byte-identical twin of the Swift `ChargeBaselinesTests` (same cases, same oracle literal).
 */
class ChargeBaselinesTest {

    private val hrvCfg = Baselines.hrvCfg
    private val rhrCfg = Baselines.restingHRCfg

    private fun dayKey(epochDay: Int): String = LocalDate.ofEpochDay(epochDay.toLong()).toString()

    /** 2026-09-30 as a day count from 1970-01-01. */
    private val anchorEpochDay = 20_726
    private val anchor = dayKey(anchorEpochDay)

    /** [count] consecutive nights ending [endBack] days before the anchor, all at [value]. */
    private fun run(count: Int, endBack: Int, value: Double?): List<Pair<String, Double?>> =
        (0 until count).map { i -> dayKey(anchorEpochDay - endBack - (count - 1 - i)) to value }

    private fun history(
        imported: List<Pair<String, Double?>>,
        own: List<Pair<String, Double?>>,
        cfg: MetricCfg = hrvCfg,
        epoch: Double = 0.0,
    ) = ChargeBaselines.history(imported, own, anchor, cfg, epoch)

    @Test fun theAnchorIsTheDayItClaims() {
        assertEquals("2026-09-30", anchor)
    }

    // ---- the window ---------------------------------------------------------------------------------

    /** The window holds the anchor and the 20 days before it; the 21st day back and any later day are out. */
    @Test fun theWindowKeepsTwentyOneCalendarDaysEndingOnTheAnchor() {
        val own = listOf(
            dayKey(anchorEpochDay - 21) to 50.0,
            dayKey(anchorEpochDay - 20) to 51.0,
            anchor to 52.0,
            dayKey(anchorEpochDay + 1) to 53.0,
        )
        val h = history(emptyList(), own)
        assertEquals(listOf("2026-09-10", "2026-09-30"), h.dayKeys)
        assertEquals(listOf(51.0, 52.0), h.values)
    }

    /** An import that ended before the window has nothing left to seed with, however few own nights exist. */
    @Test fun anImportOlderThanTheWindowDoesNotSeed() {
        val h = history(run(300, 25, 40.0), run(3, 0, 60.0))
        assertFalse(h.seededByImport)
        assertEquals(listOf(60.0, 60.0, 60.0), h.values)
        assertEquals(0, h.importedNights)
    }

    // ---- the handoff --------------------------------------------------------------------------------

    /** Thirteen valid own nights are not yet a trusted baseline, so the import still seeds; the fourteenth
     *  hands over and the import drops out entirely. */
    @Test fun importSeedsUntilTheOwnNightsAloneAreTrusted() {
        val imported = run(7, 14, 40.0)
        val seeding = history(imported, run(13, 0, 60.0))
        assertTrue(seeding.seededByImport)
        assertEquals(13, seeding.ownValidNights)
        assertEquals(7, seeding.importedNights)
        assertEquals(20, seeding.dayKeys.size)

        val handedOff = history(imported, run(14, 0, 60.0))
        assertFalse(handedOff.seededByImport)
        assertEquals(14, handedOff.ownValidNights)
        assertEquals(0, handedOff.importedNights)
        assertEquals(List(14) { 60.0 }, handedOff.values)
    }

    /** Own nights without a value exist but are not valid, so they do not bring the handoff forward. */
    @Test fun ownNightsWithoutAValueDoNotCountTowardTheHandoff() {
        val h = history(run(6, 14, 40.0), run(13, 1, 60.0) + run(1, 0, null))
        assertTrue(h.seededByImport)
        assertEquals(13, h.ownValidNights)
    }

    /** Own nights before the recalibration epoch are dropped by the fold, so they must not count here either. */
    @Test fun ownNightsBeforeTheEpochDoNotCountTowardTheHandoff() {
        val epoch = (anchorEpochDay - 9).toDouble() * 86_400 // the last ten own nights survive
        val h = history(run(3, 18, 40.0), run(30, 0, 60.0), epoch = epoch)
        assertEquals(10, h.ownValidNights)
        assertTrue(h.seededByImport)
    }

    /** Nothing that cannot be placed on the calendar is folded. */
    @Test fun unparseableKeysAreDroppedAndAnUnparseableAnchorYieldsNothing() {
        val own = listOf("garbage" to 50.0, anchor to 51.0)
        assertEquals(listOf(anchor), history(emptyList(), own).dayKeys)
        val none = ChargeBaselines.history(emptyList(), own, "not-a-day", hrvCfg, 0.0)
        assertEquals(emptyList<String>(), none.dayKeys)
        assertFalse(none.seededByImport)
    }

    // ---- seeding precedence (carried over from the pre-#2525 `mergeNightlyIntoHistory` pins) ---------

    /** An imported value wins a day the own nights also cover (import users keep their seed). */
    @Test fun whileSeedingAnImportedValueWinsASharedDay() {
        val h = history(listOf(anchor to 62.0), listOf(anchor to 48.0))
        assertTrue(h.seededByImport)
        assertEquals(listOf(62.0), h.values)
    }

    /** An own night fills a day the import does not cover. */
    @Test fun whileSeedingAnOwnNightFillsADayTheImportLacks() {
        val yesterday = dayKey(anchorEpochDay - 1)
        val h = history(listOf(yesterday to 62.0), listOf(anchor to 48.0))
        assertEquals(listOf(yesterday, anchor), h.dayKeys)
        assertEquals(listOf(62.0, 48.0), h.values)
    }

    /** A blank imported row must not shadow a night the strap measured, or an import whose rows are blank
     *  for a metric blankets every strap night and the baseline never seeds ("Needs the strap"). */
    @Test fun whileSeedingABlankImportedRowIsFilledByTheOwnNight() {
        val h = history(listOf(anchor to null), listOf(anchor to 48.0))
        assertEquals(listOf(48.0), h.values)
    }

    /** A blank imported row with no own night stays a missing night (an honest gap). */
    @Test fun whileSeedingABlankImportedRowWithNoOwnNightStaysMissing() {
        val yesterday = dayKey(anchorEpochDay - 1)
        val h = history(listOf(yesterday to null, anchor to 62.0), emptyList())
        assertTrue(h.seededByImport)
        assertEquals(listOf(yesterday, anchor), h.dayKeys)
        assertEquals(listOf(null, 62.0), h.values)
    }

    /** An own night without a value neither overwrites an imported value nor removes a blank imported day. */
    @Test fun whileSeedingABlankOwnNightDisturbsNothing() {
        val d1 = dayKey(anchorEpochDay - 2)
        val d2 = dayKey(anchorEpochDay - 1)
        val h = history(listOf(d1 to 62.0, d2 to null), listOf(d1 to null, d2 to null, anchor to null))
        assertEquals(listOf(d1, d2, anchor), h.dayKeys)
        assertEquals(listOf(62.0, null, null), h.values)
    }

    /** The starvation report's shape: a week of imported rows, all blank for HRV, over nights the strap
     *  scored. The seven measured nights must reach the fold so the baseline can seed. */
    @Test fun whileSeedingAWeekOfBlankImportedRowsStillSeedsFromTheStrap() {
        val own = (0 until 7).map { i -> dayKey(anchorEpochDay - 6 + i) to (50.0 + i) }
        val h = history(run(7, 0, null), own)
        assertEquals(7, h.values.count { it != null })
        val folded = Baselines.foldHistory(h.values, h.dayKeys, hrvCfg, 0.0)
        assertTrue(folded.nValid >= Baselines.minNightsSeed)
    }

    // ---- the defect (#2525) -------------------------------------------------------------------------

    /** A wearer whose resting HR fell from 58 during their vendor subscription to 52 since. Under the old rule
     *  (the whole import plus the last 21 own nights) the baseline stays about a third of the way back towards
     *  58 however long NOOP has been worn; under this rule it follows the wearer to 52. */
    @Test fun theBaselineFollowsTheWearerInsteadOfTheImport() {
        val imported = run(700, 181, 58.0)
        val own = run(180, 0, 52.0)
        val oldRule = Baselines.foldHistory(imported.map { it.second } + own.takeLast(21).map { it.second }, rhrCfg)
        assertEquals("the pinned third: 52 + 6 x 0.5^(21/14) is about 54.1", 54.1, oldRule.baseline, 0.2)

        val h = history(imported, own, cfg = rhrCfg)
        val folded = Baselines.foldHistory(h.values, h.dayKeys, rhrCfg, 0.0)
        assertEquals(52.0, folded.baseline, 1e-9)
    }

    /** Once the own nights have taken over, the import has no weight at all: moving every imported value
     *  leaves the baseline exactly where it was. */
    @Test fun onceHandedOffTheImportCarriesNoWeight() {
        val own = run(60, 0, 52.0)
        assertEquals(history(run(200, 10, 58.0), own, cfg = rhrCfg), history(run(200, 10, 68.0), own, cfg = rhrCfg))
    }

    /** The own nights of a varied 60-night history, as a full-history repair pass would score them. */
    private fun variedOwnNights(): List<Pair<String, Double?>> = (0 until 60).map { i ->
        dayKey(anchorEpochDay - 59 + i) to (if (i % 9 == 0) null else 45.0 + ((i * 7) % 13))
    }

    /** Without an import nothing changes on the 21-day pass: the history is exactly the nights the old rule
     *  folded (the scan window's own nights), and the folded baseline is identical. */
    @Test fun withoutAnImportTheTwentyOneDayPassIsUnchanged() {
        val scanWindow = variedOwnNights().takeLast(21)
        val oldRule = Baselines.foldHistory(scanWindow.map { it.second }, scanWindow.map { it.first }, hrvCfg, 0.0)
        val h = history(emptyList(), scanWindow)
        assertEquals(scanWindow.map { it.first }, h.dayKeys)
        assertEquals(oldRule, Baselines.foldHistory(h.values, h.dayKeys, hrvCfg, 0.0))
    }

    /** A full-history repair pass scores every day it can; the window trims it to the same 21, so the baseline
     *  no longer depends on which pass ran last. */
    @Test fun aRepairPassFoldsTheSameTwentyOneDays() {
        val all = variedOwnNights()
        assertEquals(history(emptyList(), all.takeLast(21)), history(emptyList(), all))
    }

    // ---- Resolved (the dashboard's view) ------------------------------------------------------------

    /** Resting HR follows the Charge-wide recalibration epoch in the dashboard as it does in the engine. */
    @Test fun resolveFoldsRestingHROnTheRecoveryEpoch() {
        val own = (0 until 20).map { back ->
            DailyMetric(
                deviceId = "my-whoop-noop", day = dayKey(anchorEpochDay - back),
                restingHr = if (back < 5) 50 else 60, avgHrv = 50.0,
            )
        }
        val epoch = (anchorEpochDay - 4).toDouble() * 86_400
        val r = ChargeBaselines.resolve(emptyList(), own, anchor, hrvEpoch = 0.0, recoveryEpoch = epoch)
        assertEquals(5, r.restingHR.nValid)
        assertEquals(50.0, r.restingHR.baseline, 1e-9)
        assertEquals(20, r.hrv.nValid)
    }

    // ---- diagnostic line ----------------------------------------------------------------------------

    @Test fun logLineNamesEachMetricsComposition() {
        val seeded = ChargeBaselines.History(emptyList(), emptyList(), true, 9, 40)
        val own = ChargeBaselines.History(emptyList(), emptyList(), false, 45, 0)
        assertEquals(
            "charge baseline anchor=2026-09-30 window=21d hrv=own/45 rhr=seed/9+40 resp=own/45 skin=own/45",
            ChargeBaselines.logLine("2026-09-30", own, seeded, own, own),
        )
    }

    // ---- oracle (shared with Swift) -----------------------------------------------------------------

    /** The same deterministic spread the Swift twin generates; both assert the same literal, so either side
     *  drifting fails its own suite. */
    private fun oracleLines(): List<String> {
        var s = 2525L
        fun next(): Int {
            s = s * 6_364_136_223_846_793_005L + 1_442_695_040_888_963_407L
            return (s ushr 33).toInt()
        }
        val lines = ArrayList<String>()
        for (c in 0 until 40) {
            val anchorDay = 20_089 + next() % 400
            val imported = ArrayList<Pair<String, Double?>>()
            val nImported = next() % 120
            val importEndBack = next() % 40
            for (i in 0 until nImported) {
                val value: Double? = if (next() % 10 == 0) null else 40 + (next() % 60).toDouble() / 2
                imported.add(dayKey(anchorDay - importEndBack - (nImported - 1 - i)) to value)
            }
            val own = ArrayList<Pair<String, Double?>>()
            val nOwn = next() % 30
            val ownEndBack = next() % 10
            for (i in 0 until nOwn) {
                val value: Double? = if (next() % 8 == 0) null else 35 + (next() % 80).toDouble() / 2
                own.add(dayKey(anchorDay - ownEndBack - (nOwn - 1 - i)) to value)
            }
            if (next() % 7 == 0) own.add(dayKey(anchorDay + 1) to 50.0)
            val epoch = if (next() % 5 == 0) (anchorDay - next() % 60).toDouble() * 86_400 else 0.0
            val h = ChargeBaselines.history(imported, own, dayKey(anchorDay), Baselines.hrvCfg, epoch)
            val present = h.values.filterNotNull()
            val sum = String.format(java.util.Locale.ROOT, "%.1f", present.sum())
            lines.add(
                "c=$c anchor=${dayKey(anchorDay)} n=${h.dayKeys.size} " +
                    "first=${h.dayKeys.firstOrNull() ?: "-"} last=${h.dayKeys.lastOrNull() ?: "-"} " +
                    "seeded=${if (h.seededByImport) 1 else 0} own=${h.ownValidNights} imp=${h.importedNights} " +
                    "nils=${h.values.size - present.size} sum=$sum",
            )
        }
        return lines
    }

    @Test fun oracleSpread() {
        assertEquals(oracleLiteral, oracleLines().joinToString("\n"))
    }

    private val oracleLiteral = """
        c=0 anchor=2026-01-25 n=7 first=2026-01-10 last=2026-01-16 seeded=0 own=7 imp=0 nils=0 sum=377.0
        c=1 anchor=2025-07-07 n=7 first=2025-06-17 last=2025-07-07 seeded=1 own=2 imp=5 nils=1 sum=322.0
        c=2 anchor=2025-12-01 n=13 first=2025-11-11 last=2025-11-25 seeded=1 own=9 imp=3 nils=3 sum=645.0
        c=3 anchor=2025-06-15 n=8 first=2025-05-26 last=2025-06-15 seeded=1 own=2 imp=6 nils=0 sum=435.5
        c=4 anchor=2025-08-01 n=15 first=2025-07-13 last=2025-07-27 seeded=0 own=13 imp=0 nils=2 sum=718.0
        c=5 anchor=2025-11-29 n=14 first=2025-11-14 last=2025-11-27 seeded=0 own=11 imp=0 nils=3 sum=626.5
        c=6 anchor=2025-05-06 n=12 first=2025-04-19 last=2025-04-30 seeded=0 own=11 imp=0 nils=1 sum=574.5
        c=7 anchor=2025-10-16 n=14 first=2025-10-01 last=2025-10-14 seeded=0 own=13 imp=0 nils=1 sum=673.5
        c=8 anchor=2026-01-27 n=12 first=2026-01-07 last=2026-01-18 seeded=0 own=10 imp=0 nils=2 sum=531.5
        c=9 anchor=2026-02-02 n=10 first=2026-01-13 last=2026-01-28 seeded=1 own=3 imp=7 nils=1 sum=456.5
        c=10 anchor=2025-02-01 n=14 first=2025-01-12 last=2025-01-28 seeded=1 own=5 imp=6 nils=5 sum=460.0
        c=11 anchor=2025-12-06 n=13 first=2025-11-22 last=2025-12-04 seeded=1 own=13 imp=2 nils=0 sum=687.0
        c=12 anchor=2025-07-27 n=21 first=2025-07-07 last=2025-07-27 seeded=1 own=11 imp=21 nils=0 sum=1110.0
        c=13 anchor=2025-04-30 n=9 first=2025-04-17 last=2025-04-25 seeded=0 own=8 imp=0 nils=1 sum=425.5
        c=14 anchor=2025-05-17 n=12 first=2025-04-27 last=2025-05-08 seeded=1 own=12 imp=6 nils=0 sum=603.0
        c=15 anchor=2025-06-17 n=19 first=2025-05-30 last=2025-06-17 seeded=0 own=16 imp=0 nils=3 sum=929.0
        c=16 anchor=2025-11-04 n=14 first=2025-10-16 last=2025-10-29 seeded=0 own=11 imp=0 nils=3 sum=628.5
        c=17 anchor=2025-07-22 n=10 first=2025-07-10 last=2025-07-19 seeded=0 own=8 imp=0 nils=2 sum=462.5
        c=18 anchor=2025-08-09 n=9 first=2025-07-20 last=2025-07-28 seeded=1 own=0 imp=9 nils=1 sum=402.5
        c=19 anchor=2025-01-01 n=17 first=2024-12-12 last=2024-12-28 seeded=0 own=16 imp=0 nils=1 sum=873.0
        c=20 anchor=2025-09-06 n=14 first=2025-08-19 last=2025-09-01 seeded=0 own=13 imp=0 nils=1 sum=716.5
        c=21 anchor=2025-02-05 n=2 first=2025-01-26 last=2025-01-27 seeded=0 own=2 imp=0 nils=0 sum=140.5
        c=22 anchor=2025-09-03 n=15 first=2025-08-14 last=2025-08-28 seeded=1 own=5 imp=10 nils=3 sum=701.0
        c=23 anchor=2025-11-14 n=14 first=2025-10-25 last=2025-11-07 seeded=1 own=3 imp=13 nils=0 sum=819.0
        c=24 anchor=2025-02-26 n=20 first=2025-02-06 last=2025-02-25 seeded=0 own=18 imp=0 nils=2 sum=989.0
        c=25 anchor=2025-01-27 n=15 first=2025-01-07 last=2025-01-21 seeded=0 own=13 imp=0 nils=2 sum=655.5
        c=26 anchor=2025-07-12 n=14 first=2025-06-22 last=2025-07-05 seeded=0 own=11 imp=0 nils=3 sum=583.5
        c=27 anchor=2025-12-20 n=12 first=2025-11-30 last=2025-12-11 seeded=0 own=11 imp=0 nils=1 sum=637.5
        c=28 anchor=2025-06-07 n=16 first=2025-05-18 last=2025-06-02 seeded=0 own=15 imp=0 nils=1 sum=867.0
        c=29 anchor=2025-05-29 n=18 first=2025-05-09 last=2025-05-26 seeded=0 own=14 imp=0 nils=4 sum=835.0
        c=30 anchor=2025-06-16 n=13 first=2025-05-27 last=2025-06-08 seeded=1 own=12 imp=10 nils=0 sum=644.0
        c=31 anchor=2025-08-10 n=15 first=2025-07-21 last=2025-08-04 seeded=1 own=9 imp=10 nils=1 sum=785.0
        c=32 anchor=2026-01-17 n=14 first=2025-12-28 last=2026-01-10 seeded=0 own=14 imp=0 nils=0 sum=863.5
        c=33 anchor=2026-01-10 n=21 first=2025-12-21 last=2026-01-10 seeded=1 own=12 imp=21 nils=1 sum=1130.0
        c=34 anchor=2025-08-30 n=6 first=2025-08-25 last=2025-08-30 seeded=0 own=4 imp=0 nils=2 sum=223.5
        c=35 anchor=2026-01-31 n=13 first=2026-01-11 last=2026-01-31 seeded=1 own=4 imp=9 nils=0 sum=722.5
        c=36 anchor=2025-06-22 n=5 first=2025-06-15 last=2025-06-19 seeded=0 own=5 imp=0 nils=0 sum=295.0
        c=37 anchor=2026-01-28 n=18 first=2026-01-08 last=2026-01-25 seeded=1 own=12 imp=11 nils=2 sum=844.0
        c=38 anchor=2025-05-08 n=16 first=2025-04-18 last=2025-05-03 seeded=0 own=13 imp=0 nils=3 sum=757.0
        c=39 anchor=2025-10-01 n=14 first=2025-09-11 last=2025-09-24 seeded=1 own=12 imp=8 nils=1 sum=714.5
    """.trimIndent()
}
