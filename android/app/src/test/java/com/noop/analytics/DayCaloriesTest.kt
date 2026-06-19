package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests Calories.estimateDayCalories — the APPROXIMATE whole-day HR-only energy estimate
 * (Keytel active + Harris–Benedict BMR) that backs DailyMetric.activeKcalEst and the Today
 * Calories tile for BLE-only users. Pure-function tests; no DB. Not cloud/clinical parity.
 */
class DayCaloriesTest {

    private fun hrDay(bpm: Int, n: Int): List<com.noop.data.HrSample> =
        (0 until n).map { com.noop.data.HrSample(deviceId = "test", ts = it.toLong(), bpm = bpm) }

    @Test
    fun dayCalories_emptyIsZero() {
        assertEquals(
            0.0,
            Calories.estimateDayCalories(emptyList(), UserProfile(), hrmax = 190.0, restingHR = 55.0),
            1e-12,
        )
    }

    @Test
    fun dayCalories_matchesBoutAtOneHz() {
        // At a steady 1 Hz stream the day and bout estimators agree exactly: the bout path's
        // elapsed-time weighting caps every ~1 s interval at 1 s, so it collapses to the day
        // path's flat one-second-per-sample. (They DIVERGE on gappy streams — see
        // dayPath_doesNotOverCountGappyDays — but not here.)
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val hr = hrDay(bpm = 130, n = 600) // 10 min above the active threshold, dense 1 Hz
        val day = Calories.estimateDayCalories(hr, profile, hrmax = 185.0, restingHR = 55.0)
        val bout = Calories.estimateBoutCalories(hr, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals(bout, day, 1e-9)
    }

    @Test
    fun sparseHr_tracksElapsedTimeNotSampleCount() {
        // A 10-minute effort at a steady active HR, sampled two ways over the SAME ~600 s span:
        // densely at 1 Hz, and sparsely at one sample / 10 s (the WHOOP 5/MG case). Energy must
        // track elapsed time, so the sparse estimate lands close to the dense one — NOT ~1/10th
        // of it, as the old one-second-per-sample count produced. (BOUT path only.)
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val dense = (0 until 600).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val sparse = (0 until 600 step 10).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val denseKcal = Calories.estimateBoutCalories(dense, profile, hrmax = 185.0, restingHR = 55.0).first
        val sparseKcal = Calories.estimateBoutCalories(sparse, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals("sparse HR must be counted over elapsed time, not undercounted per sample",
            denseKcal, sparseKcal, denseKcal * 0.05)
        // Teeth: a per-sample count (60 samples) would be ~1/10th of the dense total.
        assertTrue(sparseKcal > denseKcal * 0.5)
    }

    @Test
    fun wearGap_isCappedNotCreditedInFull() {
        // Two active samples an hour apart must NOT credit a full hour of active burn — the
        // per-sample interval is capped at mergeGapS (150 s). The pre-gap sample contributes
        // 150 s and the tail 1 s, so the total equals a 151 s continuous equivalent, not 3600 s.
        // (BOUT path only.)
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val gapped = listOf(
            com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
            com.noop.data.HrSample(deviceId = "t", ts = 3600L, bpm = 130),
        )
        val cappedEquiv = (0..150).map { com.noop.data.HrSample(deviceId = "t", ts = it.toLong(), bpm = 130) }
        val gappedKcal = Calories.estimateBoutCalories(gapped, profile, hrmax = 185.0, restingHR = 55.0).first
        val equivKcal = Calories.estimateBoutCalories(cappedEquiv, profile, hrmax = 185.0, restingHR = 55.0).first
        assertEquals("an inter-sample gap must be capped at mergeGapS, not credited in full",
            equivKcal, gappedKcal, equivKcal * 0.001)
    }

    @Test
    fun dayPath_doesNotOverCountGappyDays() {
        // The WHOLE-DAY estimator must STAY on one-second-per-sample, NOT the bout path's
        // elapsed-time weighting. The day feed is a raw, non-gap-filled union of HR, so a
        // single isolated elevated sample an hour from its neighbours must contribute ONE
        // second of active burn — not up to mergeGapS (150 s) of it. Two active samples an
        // hour apart therefore burn the same as two adjacent active seconds (each = 1 s),
        // proving the day path does NOT inherit the bout cap-and-credit behaviour.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val gapped = listOf(
            com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
            com.noop.data.HrSample(deviceId = "t", ts = 3600L, bpm = 130),
        )
        val twoAdjacent = listOf(
            com.noop.data.HrSample(deviceId = "t", ts = 0L, bpm = 130),
            com.noop.data.HrSample(deviceId = "t", ts = 1L, bpm = 130),
        )
        val gappedDay = Calories.estimateDayCalories(gapped, profile, hrmax = 185.0, restingHR = 55.0)
        val adjacentDay = Calories.estimateDayCalories(twoAdjacent, profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals("the day path must count each sample as exactly one second regardless of gaps",
            adjacentDay, gappedDay, 1e-9)
        // Teeth: if the day path had inherited the bout cap, the gappy total would be ~75x larger
        // (150 s + 1 s vs 1 s + 1 s of active burn). Prove it stayed flat per-sample.
        val boutGapped = Calories.estimateBoutCalories(gapped, profile, hrmax = 185.0, restingHR = 55.0).first
        assertTrue("the bout path DOES cap-and-credit, so it must dwarf the per-second day total",
            boutGapped > gappedDay * 10)
    }

    @Test
    fun dayCalories_restingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        val profile = UserProfile(weightKg = 70.0, heightCm = 170.0, age = 30.0, sex = "nonbinary")
        // Day activeThreshold = 55 + 0.50*(185-55) = 120 bpm; 60 < 120 (resting), 150 >= 120 (active).
        val restingDay = Calories.estimateDayCalories(hrDay(60, 3600), profile, hrmax = 185.0, restingHR = 55.0)
        val activeDay = Calories.estimateDayCalories(hrDay(150, 3600), profile, hrmax = 185.0, restingHR = 55.0)
        assertTrue("resting day must burn > 0 (BMR floor)", restingDay > 0.0)
        assertTrue("active day must exceed resting day", activeDay > restingDay)
    }

    @Test
    fun dayCalories_sedentaryFullDayApproximatesBMR() {
        // A full 24 h at resting HR (below the day active gate) must total ≈ the subject's BMR:
        // the day estimator floors every sub-threshold second at the resting metabolic rate, so
        // an all-rest day is BMR by construction. Standard male test subject's revised
        // Harris–Benedict BMR ≈ 1825 kcal. This is an APPROXIMATE estimate, not medical advice.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val sedentary = hrDay(55, 86_400) // 24 h, all at resting HR
        val total = Calories.estimateDayCalories(sedentary, profile, hrmax = 185.0, restingHR = 55.0)
        assertEquals("a sedentary full day must total ≈ the subject's BMR (~1825 kcal)",
            1825.25, total, 1.0)
    }

    @Test
    fun dayCalories_lightActivityDayIsFarBelowOldInflatedTotal() {
        // The bug: at the OLD 30% day gate (~94 bpm for this subject) ordinary low-intensity
        // daytime HR (~100 bpm walking/standing) was credited the FULL Keytel gross-exercise
        // rate, inflating the day total by ~1000+ kcal. The 50% day gate (120 bpm) now treats
        // that HR as resting, so a realistic mixed light day (8 h sleep @55, 8 h sedentary @70,
        // 8 h light activity @100) collapses toward BMR instead of the old runaway figure.
        val profile = UserProfile(weightKg = 80.0, heightCm = 180.0, age = 35.0, sex = "male")
        val lightDay = hrDay(55, 8 * 3_600) + hrDay(70, 8 * 3_600) + hrDay(100, 8 * 3_600)
        val total = Calories.estimateDayCalories(lightDay, profile, hrmax = 185.0, restingHR = 55.0)
        // NEW total ≈ 1825 kcal (every second below the 120 bpm gate → BMR floor).
        assertEquals("a light-activity day must land near BMR, not the old inflated total",
            1825.25, total, 1.0)
        // Teeth: the OLD 30%-gate model credited the 8 h @100 bpm block at the full Keytel active
        // rate (~3551 kcal for that block alone), so the old day total was ≈ 4768 kcal. Pin that
        // we are now WELL below it (more than 2000 kcal lower).
        assertTrue("the light-activity day must drop far below the old inflated ~4768 kcal",
            total < 4768.0 - 2000.0)
    }

    @Test
    fun analyzeDay_caloriesIgnoreAdjacentDayHr() {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val inDay = (0 until 600).map { hr(it.toLong(), 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        val withAdjacent = inDay + (0 until 600).map { hr(-36L * 3_600 - it, 120) }
        val a = AnalyticsEngine.analyzeDay(day = day, hr = inDay, profile = UserProfile()).daily.activeKcalEst
        val b = AnalyticsEngine.analyzeDay(day = day, hr = withAdjacent, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(a)
        assertNotNull(b)
        assertEquals("adjacent-day HR must not change the day's calories", a!!, b!!, 1e-6)
    }

    @Test
    fun analyzeDay_dayHrCoversFullCalendarDay() {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full calendar-day
        // HR also has the afternoon. activeKcalEst must use dayHr when supplied, so the full-day total
        // exceeds the clipped night-window total (the past-day undercount fix).
        val day = "2026-01-02"
        val noon = 1_767_355_200L // 2026-01-02T12:00:00Z
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val nightWindow = (0 until 600).map { hr(it.toLong(), 120) }
        val fullDay = nightWindow + (0 until 600).map { hr(3L * 3_600 + it, 120) }
        val clipped = AnalyticsEngine.analyzeDay(day = day, hr = nightWindow, profile = UserProfile()).daily.activeKcalEst
        val full = AnalyticsEngine.analyzeDay(
            day = day, hr = nightWindow, dayHr = fullDay, profile = UserProfile(),
        ).daily.activeKcalEst
        assertNotNull(clipped)
        assertNotNull(full)
        assertTrue("full calendar-day calories must exceed the clipped night-window total", full!! > clipped!!)
    }

    @Test
    fun analyzeDay_dayHrNullFallsBackToWindowHr() {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to passing
        // that same window explicitly as dayHr (the (dayHr ?: hr) fallback).
        val day = "2026-01-02"
        val noon = 1_767_355_200L
        fun hr(tsOffsetSec: Long, bpm: Int) =
            com.noop.data.HrSample(deviceId = "t", ts = noon + tsOffsetSec, bpm = bpm)
        val window = (0 until 600).map { hr(it.toLong(), 120) }
        val fallback = AnalyticsEngine.analyzeDay(day = day, hr = window, profile = UserProfile()).daily.activeKcalEst
        val explicit = AnalyticsEngine.analyzeDay(day = day, hr = window, dayHr = window, profile = UserProfile()).daily.activeKcalEst
        assertNotNull(fallback)
        assertNotNull(explicit)
        assertEquals(fallback!!, explicit!!, 1e-9)
    }
}
