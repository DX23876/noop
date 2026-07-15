package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the per-day scoring-diagnostic SOURCE token (Sleep overhaul §2.5). Each scored day emits
 * "sleep day=… totalSleepMin=… matched=… source=<token>" into the shareable strap log so the next
 * report ships PROOF of what was computed per day — the project's log-failures-not-successes blind
 * spot, and the data to settle "Rest repeats across days". The token resolves from the imported
 * day-key sets with the SAME precedence the dashboard merge uses (WHOOP import > Apple > computed).
 * Pure + set-based; the SAME `daySourceToken` analyzeRecent ships. Mirrors Swift DaySource.classify
 * (.logToken) so the two platforms log identical tokens.
 */
class IntelligenceDaySourceTokenTest {

    private val day = "2026-06-12"

    @Test
    fun computed_whenNoImportCoversTheDay() {
        assertEquals("computed",
            IntelligenceEngine.daySourceToken(day, emptySet(), emptySet()))
    }

    @Test
    fun importedWhoop_whenWhoopExportCoversTheDay() {
        assertEquals("imported:whoop",
            IntelligenceEngine.daySourceToken(day, setOf(day), emptySet()))
    }

    @Test
    fun importedApple_whenOnlyAppleCoversTheDay() {
        assertEquals("imported:apple",
            IntelligenceEngine.daySourceToken(day, emptySet(), setOf(day)))
    }

    @Test
    fun whoopBeatsApple_whenBothCoverTheSameDay() {
        // Must agree with the merge's source priority + the macOS classify (whoop wins over apple).
        assertEquals("imported:whoop",
            IntelligenceEngine.daySourceToken(day, setOf(day), setOf(day)))
    }

    @Test
    fun perDay_notGlobal() {
        // A set covering a DIFFERENT day leaves this day computed — the token is resolved per day,
        // which is the whole point of the honesty fix (an import elsewhere must not relabel this day).
        val imported = setOf("2026-06-10")
        assertEquals("computed", IntelligenceEngine.daySourceToken("2026-06-12", imported, emptySet()))
        assertEquals("imported:whoop", IntelligenceEngine.daySourceToken("2026-06-10", imported, emptySet()))
    }

    @Test
    fun diagnosticLineFormat_isStableAndParsable() {
        // The exact line shape the engine builds, assembled from the same parts, so the format stays
        // pinned: counts + a rounded minute only (no HR/HRV/timestamps), no em-dash. `stages=`/`eff=`
        // (#386) sit between the rollup and the counts so the rollup-vs-stages identity reads in place.
        val totalSleepMin = 423.6
        val tsm = Math.round(totalSleepMin).toString()
        val stages = IntelligenceEngine.sleepStagesLogToken(120.4, 77.2, 226.0)
        val line = "sleep day=$day totalSleepMin=$tsm stages=$stages eff=0.91 matched=2 " +
            "source=${IntelligenceEngine.daySourceToken(day, setOf(day), emptySet())}"
        assertEquals(
            "sleep day=2026-06-12 totalSleepMin=424 stages=120+77+226=424 eff=0.91 matched=2 source=imported:whoop",
            line,
        )
        assertEquals(false, line.contains("—"))
    }

    // ── stages= token (#386) ────────────────────────────────────────────────────

    @Test
    fun stagesToken_fullSplitPrintsComponentsAndSum() {
        // The sum is PRINTED (not left to the reader) so a rollup-vs-stages divergence is a one-line
        // visual check against totalSleepMin — the identity #386's screens must agree on.
        assertEquals("160+77+279=516", IntelligenceEngine.sleepStagesLogToken(159.6, 77.4, 279.2))
    }

    @Test
    fun stagesToken_componentsRoundIndividually_sumRoundsTheRawTotal() {
        // The printed sum rounds the RAW deep+rem+light (31.2 -> 31), not the rounded components
        // (10+10+10 = 30), so it matches how totalSleepMin itself is rounded and the two fields stay
        // comparable digit-for-digit.
        assertEquals("10+10+10=31", IntelligenceEngine.sleepStagesLogToken(10.4, 10.4, 10.4))
    }

    @Test
    fun stagesToken_nilWhenAnyComponentMissing() {
        // An unstaged night (or an imported day that only brought a total) must read nil, never a
        // fabricated 0-minute stage.
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(null, 77.0, 279.0))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(160.0, null, 279.0))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(160.0, 77.0, null))
        assertEquals("nil", IntelligenceEngine.sleepStagesLogToken(null, null, null))
    }
}
