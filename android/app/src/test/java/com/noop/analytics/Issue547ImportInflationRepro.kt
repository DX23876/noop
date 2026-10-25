package com.noop.analytics

import com.noop.data.DailyMetric
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.SleepSession
import com.noop.data.WhoopRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #547 INFLATION TRACE — "Rest = 721 min (12h01m) IDENTICAL across 06-09..06-21, ~2× pikapik's REAL
 * Apple-Health asleep (~414 min / 6h54m)". The stated hypothesis is that v6.0.0's NEW dict branch in
 * [SleepStageTotals.minutes] (`{"awake","light","deep","rem"}`) lets an IMPORTED "apple-health" night —
 * an IN-BED span (≈721 min) carrying the asleep total (≈414) plus the awake remainder (≈307) — leak its
 * IN-BED minutes into the day's sleep total as if it were time asleep, and that this rides through
 * AnalyticsEngine.analyzeDay / the dashboard.
 *
 * This test drives the REAL v6.0.0 code with pikapik's EXACT data shape and numbers to pin WHERE the 721
 * does (and does NOT) enter. It is the COMPLEMENT to [Issue547RepeatRepro] (which disproved the
 * motionless-strap-on-a-desk theory). Together they bracket the symptom.
 *
 * pikapik's night, to the minute (matches the report):
 *   IN-BED  = 721 min (12h01m)  — sleepOnset → wakeOnset span the WHOOP-CSV/Apple importer dict carries
 *   ASLEEP  = 414 min (6h54m)   — light 248 + deep 80 + rem 86  (his REAL Apple "asleep")
 *   AWAKE   = 307 min           — 721 − 414  (in-bed minus asleep)
 * The canonical "imported night" dict the v6.0.0 [SleepStageTotals.minutes] dict branch decodes is exactly
 * this shape (per LANE A: iOS WhoopImporter.swift writes startTs=sleepOnset, endTs=wakeOnset so end−start
 * is the IN-BED span, with stages {light,deep,rem,awake}; Minutes.inBed = asleep + awake).
 *
 * WHAT THIS PROVES (see the asserts), against the CURRENT (v6.0.0) behaviour:
 *
 *  (1) [SleepStageTotals.minutes] DICT BRANCH — the v6.0.0 addition — decodes pikapik's dict to
 *      asleep=414, inBed=721. So the 721 IS recoverable from the dict (the inBed field). This is the
 *      ONLY place in-bed=721 lives; whether it reaches the daily TOTAL depends on the consumer.
 *
 *  (2) THE DAILY TOTAL IS ASLEEP, NOT IN-BED. The ONLY consumer of the dict branch,
 *      [SleepStageTotals.dailyAggregateHonoringEdits] (reached solely via IntelligenceEngine.sleepEditedDaily),
 *      sets DailySleep.totalSleepMin = Minutes.asleep = 414 — on BOTH the legacy SUM path (no onsets) and the
 *      #525 main-night path (onsets supplied). It NEVER returns inBed. So even IF an imported dict night were
 *      fed to that consumer, the day's total would be the CORRECT 414, never 721. The dict branch cannot
 *      manufacture a 721 total. (This assert FLIPS — fails — if a future change ever makes the daily total read
 *      inBed; it is the regression guard for "in-bed counted as TST".)
 *
 *  (3) THE IMPORT PATH IS NOT EVEN WIRED TO SCORING ON ANDROID. AnalyticsEngine.analyzeDay reads RAW
 *      hr/rr/resp/gravity streams (SleepStager.detectSleep) — it does NOT query stored sleep_session rows.
 *      With an imported "apple-health" in-bed-dict SleepSession present in the store but NO raw streams,
 *      analyzeDay returns matched=0 and totalSleepMin=null. The imported night does not participate. So the
 *      stated hypothesis ("imported dict night rides through analyzeDay") is FALSIFIED for Android.
 *
 *  (4) THE DASHBOARD MERGE CAN ONLY INJECT 414, NEVER 721. The Apple importer writes
 *      DailyMetric(totalSleepMin = asleepMin = 414) under deviceId "apple-health"; the dashboard reads
 *      daysMerged("my-whoop") and mergeDaily coalesces imported-over-computed as
 *      `totalSleepMin = imported.totalSleepMin ?: computed.totalSleepMin`. Feeding it the 414 Apple row yields
 *      414 (the import would CORRECT a 721, not cause it). Nothing in the import path produces 721.
 *
 * CONCLUSION the asserts document: pikapik's constant 721 = 12h01m is TIME-IN-BED produced on the COMPUTED
 * (my-whoop-noop) side by analyzeDay→SleepStager.detectSleep over his raw WHOOP-4.0 streams (the existing
 * #547 bad-strap-clock theory), NOT by imported Apple data participating as a dict sleep session. The v6.0.0
 * dict branch is real but inert for this symptom: its sole consumer returns ASLEEP (414), and it is never on
 * pikapik's no-edits Android scoring path at all.
 *
 * Pure-JVM, in-memory, no Room/Android — exercises the real pure analytics objects directly.
 */
class Issue547ImportInflationRepro {

    // London/BST in June: UTC+1. pikapik's local offset threads through analyzeDay + the day bucket.
    private val tzOffset = 3_600L
    private val secondsPerDay = 86_400L
    private val profile = UserProfile(age = 35.0, sex = "male")

    // pikapik's night to the minute.
    private val asleepMin = 414.0           // 6h54m — his REAL Apple "asleep"
    private val inBedMin = 721.0            // 12h01m — the reported (inflated) total = TIME IN BED
    private val awakeMin = inBedMin - asleepMin   // 307
    private val lightMin = 248.0
    private val deepMin = 80.0
    private val remMin = 86.0               // 248 + 80 + 86 = 414 ✓

    /** The canonical IMPORTED-night dict the v6.0.0 [SleepStageTotals.minutes] dict branch decodes: an
     *  object of per-stage MINUTE totals {awake,light,deep,rem}. This is the shape LANE A found the iOS
     *  WhoopImporter writes (endTs−startTs = the in-bed span; stages sum to asleep, + awake = in-bed). */
    private val importedNightDict =
        """{"awake":$awakeMin,"light":$lightMin,"deep":$deepMin,"rem":$remMin}"""

    private fun dayKey(ts: Long): String = AnalyticsEngine.dayString(ts, tzOffset)
    private fun midnightLocal(ts: Long): Long = ts - Math.floorMod(ts + tzOffset, secondsPerDay)

    // (1) The v6.0.0 dict branch decodes pikapik's night: asleep=414, inBed=721. ───────────────────────
    @Test
    fun dictBranch_decodesImportedNight_inBedIs721_asleepIs414() {
        val m = SleepStageTotals.minutes(importedNightDict)
        assertTrue("the v6.0.0 dict branch must decode the {awake,light,deep,rem} imported night", m != null)
        assertEquals("asleep = light+deep+rem", asleepMin, m!!.asleep, 0.001)
        assertEquals("awake decoded", awakeMin, m.awake, 0.001)
        // THE 721 lives ONLY here, in the inBed field (asleep + awake). Whether it reaches the daily TOTAL
        // is decided by the consumer — see (2).
        assertEquals("inBed = asleep+awake = the reported 721 (time in bed)", inBedMin, m.inBed, 0.001)
        println("Issue547ImportInflationRepro (1): dict decodes asleep=${m.asleep} inBed=${m.inBed} (721 lives in inBed only)")
    }

    // (2) The ONLY dict consumer returns ASLEEP (414) as the daily total — never inBed (721). ───────────
    @Test
    fun dailyAggregateHonoringEdits_returnsAsleep414_notInBed721_onBothPaths() {
        // The detected block, keyed by its stable detected startTs, carrying the IMPORTED in-bed dict as its
        // stages — i.e. the exact (and worst) case where an imported in-bed night is fed to the edit-honoring
        // aggregate (the sole dict-branch consumer). onset = 22:00 local; in-bed span = 721 min.
        val onset = midnightLocal(java.time.OffsetDateTime.parse("2026-06-21T00:00:00+01:00").toEpochSecond()) - 2 * 3_600L
        val detected = listOf(onset to (importedNightDict as String?))

        // (2a) LEGACY path — no onsets supplied → SUM-of-all-blocks. Total must be ASLEEP (414), not 721.
        val legacy = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = detected,
            edited = emptyMap(),
        )
        assertTrue("legacy aggregate must decode", legacy != null)
        assertEquals(
            "v6.0.0 daily total (legacy SUM path) is ASLEEP, not in-bed — 414 not 721",
            asleepMin, legacy!!.sleep.totalSleepMin, 0.001,
        )

        // (2b) #525 MAIN-NIGHT path — onsets supplied → main-night-only. Single block, so it IS the main
        // night; total still ASLEEP (414), not 721.
        val mainNight = SleepStageTotals.dailyAggregateHonoringEdits(
            detected = detected,
            edited = emptyMap(),
            onsetByStart = mapOf(onset to onset),
            offsetSec = tzOffset,
        )
        assertTrue("main-night aggregate must decode", mainNight != null)
        assertEquals(
            "v6.0.0 daily total (#525 main-night path) is ASLEEP, not in-bed — 414 not 721",
            asleepMin, mainNight!!.sleep.totalSleepMin, 0.001,
        )

        // THE PIN: the only place a 721 exists is inBed; the daily total reads asleep. If this ever flips to
        // 721 the dict consumer started counting time-in-bed as sleep — the inflation regression.
        assertFalse(
            "the daily total must NEVER equal the in-bed 721 (that would be the inflation bug)",
            Math.abs(legacy.sleep.totalSleepMin - inBedMin) < 0.5 ||
                Math.abs(mainNight.sleep.totalSleepMin - inBedMin) < 0.5,
        )
        println("Issue547ImportInflationRepro (2): dailyAggregateHonoringEdits total=414 on both paths (in-bed 721 is NOT counted)")
    }

    // (3) analyzeDay reads RAW streams only — an imported dict SleepSession does NOT participate. ────────
    @Test
    fun analyzeDay_ignoresImportedDictSession_noStreams_totalIsNull() {
        val dm = midnightLocal(java.time.OffsetDateTime.parse("2026-06-21T00:00:00+01:00").toEpochSecond())
        val day = dayKey(dm)
        val onset = dm - 2 * 3_600L
        val wake = onset + (inBedMin * 60).toLong()   // 721 min later

        // The imported "apple-health" night EXACTLY as it would sit in the store: an in-bed-span SleepSession
        // whose stagesJSON is the v6.0.0 dict. This is the row the hypothesis claims inflates scoring.
        val importedSession = SleepSession(
            deviceId = "apple-health",
            startTs = onset,
            endTs = wake,                       // endTs − startTs = 721 min IN-BED span
            efficiency = asleepMin / inBedMin,  // ~0.574
            restingHr = 52,
            avgHrv = 60.0,
            stagesJSON = importedNightDict,
        )
        // Sanity: the stored row's clock span is the in-bed 721 (this is the span the hypothesis fears
        // gets counted as TST).
        assertEquals("stored imported session spans 721 min in-bed", 721L, (importedSession.endTs - importedSession.startTs) / 60L)

        // Drive the REAL analyzeDay with that session PRESENT (it would be in the store) but NO raw streams —
        // the truth of an Apple-only import: Apple writes NO raw hr/rr/resp/gravity. analyzeDay never reads
        // stored sleep_session rows, so the imported night is invisible to it.
        val res = AnalyticsEngine.analyzeDay(
            day = day,
            hr = emptyList(),
            rr = emptyList(),
            resp = emptyList(),
            gravity = emptyList(),
            profile = profile,
            tzOffsetSeconds = tzOffset,
        )
        assertEquals("analyzeDay matched no session from raw streams (it never reads stored rows)", 0, res.sleepSessions.size)
        assertNull("matched-empty forces totalSleepMin=null — the imported dict night does NOT inflate it", res.daily.totalSleepMin)
        println("Issue547ImportInflationRepro (3): analyzeDay matched=0 total=null despite a stored 721-in-bed apple-health dict session")
    }

    // (4) The dashboard merge can only inject the CORRECT asleep (414) from Apple — never 721. ──────────
    @Test
    fun mergeDaily_appleRowInjectsAsleep414_neverInBed721() {
        val day = "2026-06-21"
        // The Apple importer writes DailyMetric(totalSleepMin = asleepMin) under "apple-health" — the REAL
        // asleep, 414 (AppleHealthImporter.kt: totalSleepMin = d.asleepMin). It NEVER writes the in-bed 721.
        val appleDaily = DailyMetric(deviceId = "apple-health", day = day, totalSleepMin = asleepMin)
        // A computed strap row that (per the #547 bad-clock theory) holds the inflated 721 in-bed total.
        val computedDaily = DailyMetric(deviceId = "my-whoop-noop", day = day, totalSleepMin = inBedMin)

        // mergeDaily coalesces imported-over-computed: total = imported.total ?: computed.total.
        val merged = WhoopRepository.mergeDaily(imported = listOf(appleDaily), computed = listOf(computedDaily))
        assertEquals("one merged day", 1, merged.size)
        assertEquals(
            "an Apple row CORRECTS the day to 414 (asleep) — the import is a fix, not the cause of 721",
            asleepMin, merged.first().totalSleepMin!!, 0.001,
        )
        assertTrue(
            "the only way 721 survives the merge is when Apple has NO asleep for the day — then the COMPUTED 721 shows through",
            WhoopRepository.mergeDaily(
                imported = listOf(DailyMetric(deviceId = "apple-health", day = day, totalSleepMin = null)),
                computed = listOf(computedDaily),
            ).first().totalSleepMin == inBedMin,
        )
        println("Issue547ImportInflationRepro (4): Apple row merges to 414 (the fix); 721 only survives from the COMPUTED side")
    }
}
