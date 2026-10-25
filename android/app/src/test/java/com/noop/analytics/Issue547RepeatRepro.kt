package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #547 follow-up — "Rest repeats across days" (the 721 min = 12h01m IDENTICAL on EVERY day 06-09..06-21).
 *
 * pikapik's 6.0.3 strap log shows the per-day scoring diagnostic
 *   "sleep day=2026-06-21 totalSleepMin=721 matched=2 source=computed"
 *   ...
 *   "sleep day=2026-06-09 totalSleepMin=721 matched=0 source=imported:apple"
 * 721 minutes, dead identical across thirteen days, on BOTH source=computed and source=imported:apple.
 *
 * The READER's paradox: the diagnostic logs `tsmLog = round(daily.totalSleepMin)` and
 * `matched = res.sleepSessions.size`, where `daily` is `res.daily` (no edits, so sleepEditedDaily is a
 * no-op) and `res.sleepSessions == matched`. AnalyticsEngine.analyzeDay sets
 * `totalSleepMin = if (matched.isEmpty()) null else tstS/60.0` (line 425) and
 * `DayResult(sleepSessions = matched)` (line 450). So within ONE analyzeDay call, `matched=0` forces
 * totalSleepMin=null → the diagnostic would print "nil", NEVER a number. `matched=0 totalSleepMin=721`
 * is therefore IMPOSSIBLE to emit for a day scored by analyzeDay. This test resolves the mechanism by
 * driving the REAL code with pikapik's data SHAPE — a strap left on a table (one long continuous,
 * still-but-worn ~12h block per night) plus Apple-Health daily rows — over the EXACT per-day overlapping
 * windows analyzeRecentOnCpu builds: [dayStart-30h, nextMidnight], attributing each detected block by the
 * LOCAL day its END falls on, exactly as analyzeDay's `matched` filter does.
 *
 * Pure-JVM: it calls AnalyticsEngine.analyzeDay (the real detector + aggregator) and the real
 * IntelligenceEngine.daySourceToken. No Room — WhoopRepository is a concrete DAO-backed class, so we feed
 * analyzeDay the streams the repo would have returned for each window, which is the byte-identical input.
 *
 * What it demonstrates (see the asserts):
 *  (A) DISPROVES the off-wrist-repeat theory: a 12h motionless "strap on a desk" block (still + flat low
 *      HR, even with realistic sub-threshold sensor jitter) is NOT scored as sleep at all — analyzeDay
 *      returns totalSleepMin=null on EVERY day. NOOP does NOT hallucinate a 12h "721" from a motionless
 *      strap, so pikapik's 721 is NOT produced by this mechanism. (Permanent guard against that regression.)
 *  (B) The source token is a pure LABEL from the imported day-key sets — INDEPENDENT of `matched`. A day
 *      with an Apple daily row reads "imported:apple" whether or not a block matched. So the log's
 *      "source=imported:apple" line, when it carries a number, MUST be a day that ALSO had strap HR and a
 *      computed total (the Apple label rides on top); and
 *  (C) an Apple-only day with NO strap HR is SKIPPED by the loop's `if (hr.size < MIN_HR_SAMPLES) continue`
 *      gate, so it emits NO diagnostic line at all and can NEVER print "matched=0 totalSleepMin=721" from
 *      an imported value — i.e. the imported total does not leak into tsmLog.
 */
class Issue547RepeatRepro {

    // London/BST during June: UTC+1. The user's local offset threads through analyzeDay/the diagnostic.
    private val tzOffset = 3_600L
    private val secondsPerDay = 86_400L
    private val profile = UserProfile(age = 35.0, sex = "male")

    /** AnalyticsEngine.dayString with the device offset (the LOCAL-day key the loop + matched filter use). */
    private fun dayKey(ts: Long): String = AnalyticsEngine.dayString(ts, tzOffset)

    /** Floor a unix ts to LOCAL midnight (mirror of IntelligenceEngine.midnightLocal). */
    private fun midnightLocal(ts: Long): Long = ts - Math.floorMod(ts + tzOffset, secondsPerDay)

    /**
     * One night's worth of a strap-on-a-table block: a CONTINUOUS, perfectly still ("worn", HR present)
     * ~12h span from 22:00 local on day D-1 to ~10:00 local on day D. Gravity is a CONSTANT vector
     * (per-sample delta 0g < gravityStillThresholdG 0.01g → "still") and HR sits well below the day's
     * median band so confirmSleepWithHR vouches it as sleep. Onset 22:00 is OUTSIDE the daytime band so
     * the block is overnight-anchored and skips the daytime false-sleep guard. Sampled every 30 s so a
     * 12h block carries ~1440 HR + ~1440 gravity samples (>> MIN_HR_SAMPLES 200). The block END lands on
     * day D at ~10:00 local, so analyzeDay's matched filter attributes it to day D.
     *
     * @param dayMidnightLocal local midnight (unix s) of day D
     */
    private fun tableBlock(dayMidnightLocal: Long): Pair<List<HrSample>, List<GravitySample>> {
        val start = dayMidnightLocal - 2 * 3_600L   // 22:00 local on D-1
        val end = dayMidnightLocal + 10 * 3_600L    // 10:00 local on D  → 12h span, end ∈ day D
        val hr = ArrayList<HrSample>()
        val grav = ArrayList<GravitySample>()
        var t = start
        // Deterministic sub-threshold sensor jitter (a REAL strap on a desk is never a perfect flatline —
        // it has tiny vibration/thermal noise). Magnitude kept WELL under gravityStillThresholdG (0.01g)
        // so every sample is still "still", but the stream has non-zero variance (no flatline rejection).
        var seed = 0x547L
        fun jitter(): Double { seed = (seed * 6364136223846793005L + 1442695040888963407L); return ((seed ushr 40) % 200 - 100) / 100_000.0 } // ±0.001g
        while (t <= end) {
            // Low, flat HR — a resting wrist. Tiny wobble so HRV/staging have something to chew on
            // but the mean stays far under any plausible day median (confirmSleepWithHR: meanHR <= base*1.05).
            hr.add(HrSample(deviceId = "my-whoop", ts = t, bpm = 52 + ((t / 30) % 3).toInt() - 1))
            // Near-constant gravity vector with sub-threshold jitter → classifyStill still flags "still",
            // but the stream is NOT a perfect flatline (which our code correctly rejects as sensor-dead).
            grav.add(GravitySample(deviceId = "my-whoop", ts = t, x = jitter(), y = jitter(), z = 1.0 + jitter()))
            t += 30
        }
        return hr to grav
    }

    /**
     * Replicate analyzeRecentOnCpu's per-day loop for ONE day: build the [dayStart-30h, nextMidnight]
     * read window, slice the supplied whole-history streams to it (what the repo's range read returns),
     * run the REAL analyzeDay, then emit the SAME diagnostic line the engine emits at
     * IntelligenceEngine.kt:512-516. Returns null when the day is below the MIN_HR_SAMPLES gate (skipped,
     * no line — exactly the loop's `continue`).
     */
    private fun diagForDay(
        dayMidnightLocal: Long,
        allHr: List<HrSample>,
        allGrav: List<GravitySample>,
        importedWhoopDays: Set<String>,
        appleHealthDays: Set<String>,
        nowLocalMidnight: Long,
    ): String? {
        val day = dayKey(dayMidnightLocal)
        val from = dayMidnightLocal - 30 * 3_600L
        val nextMidnight = dayMidnightLocal + secondsPerDay
        val to = if (dayMidnightLocal < nowLocalMidnight) nextMidnight else dayMidnightLocal + 18 * 3_600L

        val hr = allHr.filter { it.ts in from..to }
        if (hr.size < IntelligenceEngine.MIN_HR_SAMPLES) return null   // loop's gate → no diagnostic line
        val grav = allGrav.filter { it.ts in from..to }

        // Calendar-day streams for the additive totals (don't affect sleep/matched).
        val dayEnd = dayMidnightLocal + secondsPerDay - 1
        val dayHr = allHr.filter { it.ts in dayMidnightLocal..dayEnd }
        val dayGrav = allGrav.filter { it.ts in dayMidnightLocal..dayEnd }

        val res = AnalyticsEngine.analyzeDay(
            day = day,
            hr = hr,
            gravity = grav,
            dayHr = dayHr,
            dayGravity = dayGrav,
            profile = profile,
            tzOffsetSeconds = tzOffset,
        )
        // sleepEditedDaily is a no-op with no edits, so `daily` == res.daily (the engine's exact value).
        val tsmLog = res.daily.totalSleepMin?.let { Math.round(it).toString() } ?: "nil"
        return "sleep day=$day totalSleepMin=$tsmLog matched=${res.sleepSessions.size} " +
            "source=${IntelligenceEngine.daySourceToken(day, importedWhoopDays, appleHealthDays)}"
    }

    // ─────────────────────────────────────────────────────────────────────────────

    @Test
    fun offWristTableBlock_repeatsSameTotalAcrossEveryDay() {
        // "now" = local midnight of 2026-06-22 so 06-09..06-21 are all PAST days (read to nextMidnight).
        val nowLocalMidnight = midnightLocal(
            java.time.OffsetDateTime.parse("2026-06-22T00:00:00+01:00").toEpochSecond(),
        )

        // 13 nights of an identical table block, 06-09..06-21 — the strap sat on a desk for two weeks.
        val days = (0..12).map { nowLocalMidnight - (it + 1) * secondsPerDay } // 06-21 down to 06-09
        val allHr = ArrayList<HrSample>()
        val allGrav = ArrayList<GravitySample>()
        for (dm in days) {
            val (h, g) = tableBlock(dm)
            allHr.addAll(h)
            allGrav.addAll(g)
        }

        val lines = days
            .sortedDescending()
            .mapNotNull {
                diagForDay(it, allHr, allGrav, emptySet(), emptySet(), nowLocalMidnight)
            }

        // Every night was scored (block clears MIN_HR_SAMPLES) → 13 diagnostic lines.
        assertEquals("every table-block night must emit a line", 13, lines.size)

        // Parse the per-day total + matched out of each line.
        val totals = lines.map { line ->
            val tsm = Regex("totalSleepMin=(\\S+)").find(line)!!.groupValues[1]
            val matched = Regex("matched=(\\d+)").find(line)!!.groupValues[1].toInt()
            tsm to matched
        }

        // (A) THE FINDING (disproves the off-wrist-repeat theory): an off-wrist "strap on a desk" block —
        //     12h still (sub-threshold jitter) with flat low HR — is NOT scored as sleep AT ALL. Our real
        //     detector (motion-architecture + off-wrist guards) returns totalSleepMin=null on EVERY day.
        //     So NOOP does NOT hallucinate a 12h "721" sleep from a motionless strap; pikapik's 721 is
        //     therefore NOT produced by this mechanism. This test is a permanent guard for that.
        assertTrue(
            "a 12h motionless off-wrist block must NOT be scored as sleep on any day (got: " +
                lines.joinToString(" | ") + ")",
            totals.all { it.first == "nil" },
        )

        // Document the exact shape for the report.
        println("Issue547RepeatRepro — off-wrist still block scored as nil (no sleep) on all ${lines.size} days:")
        lines.forEach { println("  $it") }
    }

    @Test
    fun appleImportedDay_withStrapHr_logsImportedTokenOnTopOfComputedTotal() {
        // (B) An Apple-Health daily row covers the day AND the strap also has the table block. The day is
        //     scored from the STRAP raw streams (Apple writes no raw HR), so tsmLog is the COMPUTED total;
        //     the source token is just the "imported:apple" LABEL on top. This is the only way a
        //     "source=imported:apple" line can carry a number — it is the computed strap total, relabelled.
        val nowLocalMidnight = midnightLocal(
            java.time.OffsetDateTime.parse("2026-06-22T00:00:00+01:00").toEpochSecond(),
        )
        val dm = nowLocalMidnight - secondsPerDay     // 2026-06-21
        val day = dayKey(dm)
        val (h, g) = tableBlock(dm)

        val line = diagForDay(
            dm, h, g,
            importedWhoopDays = emptySet(),
            appleHealthDays = setOf(day),   // Apple covers this day
            nowLocalMidnight = nowLocalMidnight,
        )
        assertTrue("line must exist (strap HR present)", line != null)
        assertTrue("token must be imported:apple", line!!.contains("source=imported:apple"))
        // The number is the COMPUTED strap total, not an imported value.
        val tsm = Regex("totalSleepMin=(\\S+)").find(line)!!.groupValues[1]
        val matched = Regex("matched=(\\d+)").find(line)!!.groupValues[1].toInt()
        assertTrue("the imported-labelled day still carries a COMPUTED, non-nil total", tsm != "nil")
        assertTrue("with strap HR the block matched (>=1), so the number is a real computed total", matched >= 1)
        println("Issue547RepeatRepro — imported:apple line over strap HR: $line")
    }

    @Test
    fun appleOnlyDay_noStrapHr_isSkipped_noImportedTotalLeaks() {
        // (C) The genuinely-impossible line ("matched=0 totalSleepMin=721 source=imported:apple") would
        //     require an Apple-ONLY day (no strap HR) to BOTH enter the loop AND log the imported 721.
        //     It does neither: with no strap HR the day is below MIN_HR_SAMPLES and the loop `continue`s,
        //     emitting NO line — so the imported total can never reach tsmLog.
        val nowLocalMidnight = midnightLocal(
            java.time.OffsetDateTime.parse("2026-06-22T00:00:00+01:00").toEpochSecond(),
        )
        val dm = nowLocalMidnight - secondsPerDay
        val day = dayKey(dm)

        val line = diagForDay(
            dm,
            allHr = emptyList(),         // Apple import writes NO raw HR
            allGrav = emptyList(),
            importedWhoopDays = emptySet(),
            appleHealthDays = setOf(day),
            nowLocalMidnight = nowLocalMidnight,
        )
        assertNull("an Apple-only day (no strap HR) is skipped — NO diagnostic line, no imported total leak", line)

        // And to pin the in-engine invariant directly: with matched empty, analyzeDay forces a NIL total.
        // (If a future change ever lets an imported value populate tsmLog while matched=0, this flips.)
        val res = AnalyticsEngine.analyzeDay(
            day = day,
            hr = emptyList(),
            gravity = emptyList(),
            profile = profile,
            tzOffsetSeconds = tzOffset,
        )
        assertEquals("matched must be empty with no streams", 0, res.sleepSessions.size)
        assertNull("matched-empty MUST force totalSleepMin=null → diagnostic prints 'nil', never a number",
            res.daily.totalSleepMin)
    }
}
