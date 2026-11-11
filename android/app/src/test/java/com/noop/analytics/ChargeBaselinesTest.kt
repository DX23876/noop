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

    /** The window holds the anchor and the 89 days before it; the 90th day back and any later day are out (AI-35). */
    @Test fun theWindowKeepsNinetyCalendarDaysEndingOnTheAnchor() {
        assertEquals(90, ChargeBaselines.windowDays)
        val own = listOf(
            dayKey(anchorEpochDay - 90) to 50.0,
            dayKey(anchorEpochDay - 89) to 51.0,
            anchor to 52.0,
            dayKey(anchorEpochDay + 1) to 53.0,
        )
        val h = history(emptyList(), own)
        assertEquals(listOf("2026-07-03", "2026-09-30"), h.dayKeys)
        assertEquals(listOf(51.0, 52.0), h.values)
    }

    /** An import that ended before the window has nothing left to seed with, however few own nights exist. */
    @Test fun anImportOlderThanTheWindowDoesNotSeed() {
        val h = history(run(300, 95, 40.0), run(3, 0, 60.0))
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

    /** Without an import the history is exactly the own nights of the window, in day order. */
    @Test fun withoutAnImportTheHistoryIsTheWindowsOwnNights() {
        val nights = variedOwnNights()
        val h = history(emptyList(), nights.shuffled())
        assertEquals(nights.map { it.first }, h.dayKeys)
        assertEquals(nights.map { it.second }, h.values)
    }

    /** A full-history repair pass and a short pass give a day the same history: nights older than the window
     *  fall out, so the baseline no longer depends on which pass ran last. */
    @Test fun aRepairPassFoldsTheSameWindowAsAShortPass() {
        val all = (0 until 200).map { i -> dayKey(anchorEpochDay - 199 + i) to (45.0 + ((i * 7) % 13)) as Double? }
        assertEquals(history(emptyList(), all.takeLast(ChargeBaselines.windowDays)), history(emptyList(), all))
    }

    // ---- The scored day (AI-35) ----------------------------------------------------------------------

    @Test fun theAnchorOfAScoredDayIsTheDayBefore() {
        assertEquals("2026-09-30", ChargeBaselines.anchorDayFor("2026-10-01"))
        assertEquals("2026-02-28", ChargeBaselines.anchorDayFor("2026-03-01"))
        assertEquals(null, ChargeBaselines.anchorDayFor("not-a-day"))
    }

    private fun row(back: Int, hrv: Double, rhr: Int) =
        DailyMetric(deviceId = "my-whoop-noop", day = dayKey(anchorEpochDay - back), restingHr = rhr, avgHrv = hrv)

    @Test fun aScoredNightIsNotPartOfItsOwnBaseline() {
        val earlier = (1..20).map { row(it, 50.0, 55) }
        val r = ChargeBaselines.resolve(emptyList(), earlier + row(0, 20.0, 70), anchor, 0.0, 0.0)
        assertEquals(ChargeBaselines.resolve(emptyList(), earlier, anchor, 0.0, 0.0), r)
        assertEquals(20, r.hrv.nValid)
    }

    @Test fun laterNightsDoNotMoveAnEarlierDaysBaseline() {
        val history = (0 until 30).map { row(it + 10, 40.0 + it % 7, 60 - it % 5) }
        val later = (0 until 10).map { row(it, 90.0, 45) }
        val scored = dayKey(anchorEpochDay - 9)
        assertEquals(ChargeBaselines.resolve(emptyList(), history, scored, 0.0, 0.0),
                     ChargeBaselines.resolve(emptyList(), history + later, scored, 0.0, 0.0))
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
        // Scored the day after the anchor, so the anchor's night is the newest the baseline reads (AI-35).
        val r = ChargeBaselines.resolve(emptyList(), own, dayKey(anchorEpochDay + 1), hrvEpoch = 0.0, recoveryEpoch = epoch)
        assertEquals(5, r.restingHR.nValid)
        assertEquals(50.0, r.restingHR.baseline, 1e-9)
        assertEquals(20, r.hrv.nValid)
    }

    // ---- diagnostic line ----------------------------------------------------------------------------

    @Test fun logLineNamesEachMetricsComposition() {
        val seeded = ChargeBaselines.History(emptyList(), emptyList(), true, 9, 40)
        val own = ChargeBaselines.History(emptyList(), emptyList(), false, 45, 0)
        assertEquals(
            "charge baseline anchor=2026-09-30 window=90d hrv=own/45 rhr=seed/9+40 resp=own/45 skin=own/45",
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
        c=0 anchor=2026-01-25 n=12 first=2025-12-18 last=2026-01-16 seeded=1 own=7 imp=5 nils=0 sum=668.5
        c=1 anchor=2025-07-07 n=54 first=2025-05-01 last=2025-07-07 seeded=1 own=2 imp=52 nils=5 sum=2672.0
        c=2 anchor=2025-12-01 n=82 first=2025-09-03 last=2025-11-25 seeded=1 own=9 imp=72 nils=11 sum=4011.5
        c=3 anchor=2025-06-15 n=59 first=2025-04-05 last=2025-06-15 seeded=1 own=2 imp=57 nils=6 sum=2860.0
        c=4 anchor=2025-08-01 n=70 first=2025-05-15 last=2025-07-27 seeded=1 own=13 imp=55 nils=8 sum=3361.0
        c=5 anchor=2025-11-29 n=80 first=2025-09-01 last=2025-11-27 seeded=1 own=11 imp=66 nils=10 sum=3987.0
        c=6 anchor=2025-05-06 n=81 first=2025-02-06 last=2025-04-30 seeded=1 own=11 imp=69 nils=13 sum=3776.0
        c=7 anchor=2025-10-16 n=68 first=2025-07-19 last=2025-10-14 seeded=1 own=13 imp=54 nils=5 sum=3339.5
        c=8 anchor=2026-01-27 n=29 first=2025-12-04 last=2026-01-18 seeded=1 own=10 imp=17 nils=3 sum=1394.5
        c=9 anchor=2026-02-02 n=74 first=2025-11-10 last=2026-01-28 seeded=1 own=3 imp=71 nils=5 sum=3649.5
        c=10 anchor=2025-02-01 n=83 first=2024-11-04 last=2025-01-28 seeded=1 own=5 imp=75 nils=8 sum=4020.5
        c=11 anchor=2025-12-06 n=13 first=2025-11-22 last=2025-12-04 seeded=1 own=13 imp=2 nils=0 sum=687.0
        c=12 anchor=2025-07-27 n=20 first=2025-06-30 last=2025-07-19 seeded=0 own=18 imp=0 nils=2 sum=980.0
        c=13 anchor=2025-04-30 n=71 first=2025-02-02 last=2025-04-25 seeded=1 own=8 imp=62 nils=8 sum=3431.5
        c=14 anchor=2025-05-17 n=21 first=2025-04-18 last=2025-05-08 seeded=0 own=21 imp=0 nils=0 sum=1134.0
        c=15 anchor=2025-06-17 n=19 first=2025-05-30 last=2025-06-17 seeded=0 own=16 imp=0 nils=3 sum=929.0
        c=16 anchor=2025-11-04 n=69 first=2025-08-07 last=2025-10-29 seeded=1 own=11 imp=55 nils=8 sum=3376.5
        c=17 anchor=2025-07-22 n=47 first=2025-05-26 last=2025-07-19 seeded=1 own=8 imp=37 nils=3 sum=2403.5
        c=18 anchor=2025-08-09 n=16 first=2025-07-13 last=2025-07-28 seeded=1 own=0 imp=16 nils=1 sum=762.5
        c=19 anchor=2025-01-01 n=17 first=2024-12-12 last=2024-12-28 seeded=0 own=16 imp=0 nils=1 sum=873.0
        c=20 anchor=2025-09-06 n=68 first=2025-06-09 last=2025-09-01 seeded=1 own=13 imp=54 nils=4 sum=3502.0
        c=21 anchor=2025-02-05 n=60 first=2024-11-08 last=2025-01-27 seeded=1 own=2 imp=58 nils=5 sum=3012.0
        c=22 anchor=2025-09-03 n=73 first=2025-06-17 last=2025-08-28 seeded=1 own=5 imp=68 nils=12 sum=3454.0
        c=23 anchor=2025-11-14 n=83 first=2025-08-17 last=2025-11-07 seeded=1 own=3 imp=82 nils=9 sum=4184.5
        c=24 anchor=2025-02-26 n=25 first=2025-02-01 last=2025-02-25 seeded=0 own=23 imp=0 nils=2 sum=1272.0
        c=25 anchor=2025-01-27 n=24 first=2024-12-29 last=2025-01-21 seeded=0 own=22 imp=0 nils=2 sum=1166.0
        c=26 anchor=2025-07-12 n=24 first=2025-06-12 last=2025-07-05 seeded=0 own=21 imp=0 nils=3 sum=1119.5
        c=27 anchor=2025-12-20 n=22 first=2025-11-20 last=2025-12-11 seeded=0 own=20 imp=0 nils=2 sum=1107.5
        c=28 anchor=2025-06-07 n=20 first=2025-05-14 last=2025-06-02 seeded=0 own=17 imp=0 nils=3 sum=952.0
        c=29 anchor=2025-05-29 n=23 first=2025-05-04 last=2025-05-26 seeded=0 own=19 imp=0 nils=4 sum=1097.0
        c=30 anchor=2025-06-16 n=82 first=2025-03-19 last=2025-06-08 seeded=1 own=12 imp=79 nils=7 sum=4093.0
        c=31 anchor=2025-08-10 n=66 first=2025-05-31 last=2025-08-04 seeded=1 own=9 imp=61 nils=9 sum=3186.0
        c=32 anchor=2026-01-17 n=20 first=2025-12-22 last=2026-01-10 seeded=0 own=18 imp=0 nils=2 sum=1027.0
        c=33 anchor=2026-01-10 n=20 first=2025-12-15 last=2026-01-03 seeded=0 own=18 imp=0 nils=2 sum=1040.0
        c=34 anchor=2025-08-30 n=66 first=2025-06-02 last=2025-08-30 seeded=1 own=4 imp=60 nils=3 sum=3438.0
        c=35 anchor=2026-01-31 n=57 first=2025-11-28 last=2026-01-31 seeded=1 own=4 imp=53 nils=7 sum=2873.0
        c=36 anchor=2025-06-22 n=52 first=2025-04-12 last=2025-06-19 seeded=1 own=5 imp=47 nils=4 sum=2674.5
        c=37 anchor=2026-01-28 n=87 first=2025-10-31 last=2026-01-25 seeded=1 own=12 imp=80 nils=7 sum=4351.0
        c=38 anchor=2025-05-08 n=18 first=2025-04-16 last=2025-05-03 seeded=0 own=14 imp=0 nils=4 sum=810.0
        c=39 anchor=2025-10-01 n=22 first=2025-09-03 last=2025-09-24 seeded=0 own=19 imp=0 nils=3 sum=1075.0
    """.trimIndent()
}
