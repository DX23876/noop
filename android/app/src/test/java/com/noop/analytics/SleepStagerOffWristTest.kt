package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests SleepStager's off-wrist backstop (#500), FRACTIONAL rule (#504; design credited to j0b-dev).
 * A wrist-OFF stretch reads as perfectly still gravity with no contrary motion, so the gravity spine
 * classifies it as sleep — and because the off-wrist epochs carry zero/missing HR the daytime guard
 * treats them as "missing data" and lets them through. The backstop measures off-wrist COVERAGE — the
 * union of a run's long HR-coverage gaps (≥ offWristHRGapMin = 20 min) and any WRIST_OFF→WRIST_ON
 * intervals — and drops the run only when that reaches maxOffWristSleepFraction (0.5) of its duration,
 * so a real night that over-extends into a SHORT off-wrist tail survives. Faithful Kotlin mirror of the
 * off-wrist cases in SleepStagerTests.swift.
 */
class SleepStagerOffWristTest {

    private val dev = "test"

    /** 2025-06-10 00:00:00 UTC — an arbitrary fixed midnight (ref % 86400 == 0). */
    private val refMidnight = 1_749_513_600L

    private fun startAtHour(hourUTC: Int): Long = refMidnight + hourUTC * 3_600L

    private fun stillGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    private fun activeGravity(start: Long, durationS: Int): List<GravitySample> =
        (0 until durationS).map { i ->
            val phase = (i % 2) * 0.5
            GravitySample(deviceId = dev, ts = start + i, x = phase, y = 0.0, z = 1.0)
        }

    private fun hrStream(start: Long, durationS: Int, bpm: Int): List<HrSample> =
        (0 until durationS).map { HrSample(deviceId = dev, ts = start + it, bpm = bpm) }

    @Test
    fun offWristDaytimeGapNotSleep() {
        // A long, still daytime stretch where HR has a >20-min contiguous gap (strap off the wrist)
        // must NOT be classified as sleep. The dip-confirming HR before the gap would even satisfy
        // the daytime guard, so ONLY the HR-gap backstop rejects it.
        val dayStart = startAtHour(10)          // 10:00 active context, HR 72 (lifts the baseline)
        val dayDur = 2 * 60 * 60
        val dayGrav = activeGravity(dayStart, dayDur)
        val dayHR = hrStream(dayStart, dayDur, 72)

        // 12:00 the strap goes still on a desk for 2 h (≥90-min daytime minimum, center in [11,20)).
        val offStart = dayStart + dayDur
        val offDur = 2 * 60 * 60
        val offGrav = stillGravity(offStart, offDur)
        // HR covers only the FIRST 20 min at a low 50 bpm (a real dip), then NOTHING — a >20-min gap.
        val offHR = hrStream(offStart, 20 * 60, 50)

        val sessions = SleepStager.detectSleep(hr = dayHR + offHR, gravity = dayGrav + offGrav)
        assertTrue(
            "a still daytime stretch with a >20-min HR-coverage gap is off-wrist, not sleep",
            sessions.isEmpty(),
        )
    }

    @Test
    fun wornNightWithDenseHRStillRegisters() {
        // The backstop must NOT suppress a genuine worn night: dense 1 Hz HR has no gap.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals("a worn night with dense, gap-free HR must still register", 1, sessions.size)
    }

    @Test
    fun realNightWithShortOffWristTailIsKept_hrGapPath() {
        // THE critical case j0b-dev's #504 designed (HR-gap path): a real overnight night whose detected
        // still period over-extends into a SHORT off-wrist morning tail — the user takes the strap off
        // shortly after waking, so the tail flatlines to no HR — is KEPT. The old binary guard dropped the
        // WHOLE night on that one trailing gap; the fractional rule keeps it (the tail is < 50% of the
        // period). Here: ~3.5 h worn (dense HR) + 30 min off-wrist tail (no HR) ⇒ ~12.5% off-wrist.
        val start = startAtHour(1)
        val wornDur = 210 * 60                  // 3.5 h worn, dense 1 Hz HR
        val tailDur = 30 * 60                   // 30 min off-wrist tail: still gravity, NO HR
        val grav = stillGravity(start, wornDur + tailDur)   // one continuous still run
        val hr = hrStream(start, wornDur, 50)               // HR stops at the wake
        val sessions = SleepStager.detectSleep(hr = hr, gravity = grav)
        assertEquals(
            "a real night with a short (<50%) off-wrist morning tail must be KEPT, not dropped",
            1, sessions.size,
        )
    }

    @Test
    fun realNightWithShortOffWristTailIsKept_intervalPath() {
        // FRACTIONAL rule (#504), explicit-interval variant: a real night whose detected period
        // over-extends into a short off-wrist tail covered by an explicit WRIST_OFF→WRIST_ON interval
        // (HR is dense the whole window, e.g. a 5/MG still streaming PPG-HR) is KEPT — < 50% coverage.
        val start = startAtHour(1)
        val dur = 240 * 60                      // 4 h, dense HR throughout
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        // Strap removed for the last 30 min (12.5% of the run) → tiny overlap, keep the night.
        val sessions = SleepStager.detectSleep(
            hr = hr, gravity = grav,
            wristOff = listOf((start + dur - 30 * 60) to (start + dur)),
        )
        assertEquals("a real night with a short (<50%) explicit off-wrist tail must be KEPT", 1, sessions.size)
    }

    @Test
    fun wristOffIntervalCoveringMostOfRunDropsIt() {
        // The explicit-interval path (#500), FRACTIONAL rule (#504): a WRIST_OFF→WRIST_ON interval that
        // covers most of an otherwise-valid overnight window drops it — coverage ≥ maxOffWristSleepFraction.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        assertEquals(1, SleepStager.detectSleep(hr = hr, gravity = grav).size)
        val dropped = SleepStager.detectSleep(
            hr = hr, gravity = grav,
            wristOff = listOf((start + 5 * 60) to (start + dur)),
        )
        assertTrue("a WRIST_OFF interval covering ≥50% of the run must drop it", dropped.isEmpty())
    }

    @Test
    fun briefWristOffBlipKeepsWornNight() {
        // FRACTIONAL rule (#504): a single BRIEF WRIST_OFF blip (well under 50% of the run) must NOT drop
        // a real, dense, worn night — the flaw the binary "any WRIST_OFF drops it" guard had. Here a
        // 5-min off-wrist interval over a 90-min night is ~5.5% coverage, so the night is kept.
        val start = startAtHour(2)
        val dur = 90 * 60
        val grav = stillGravity(start, dur)
        val hr = hrStream(start, dur, 50)
        val kept = SleepStager.detectSleep(
            hr = hr, gravity = grav,
            wristOff = listOf((start + 30 * 60) to (start + 35 * 60)),
        )
        assertEquals("a brief (<50%) WRIST_OFF blip must NOT drop a real worn night", 1, kept.size)
    }

    @Test
    fun offWristFractionAndGapSpans() {
        // The fractional helpers are precise about the threshold, edges, and the union.
        val p = SleepStager.Period(stage = "sleep", start = 0L, end = 3_600L)
        // Dense coverage → no gap span, zero fraction.
        val dense = (0..3_600).map { HrSample(deviceId = dev, ts = it.toLong(), bpm = 50) }
        assertTrue(SleepStager.offWristHRGapSpans(p, dense).isEmpty())
        assertEquals(0.0, SleepStager.offWristFraction(p, dense, emptyList()), 1e-9)
        // A single 21-min interior gap (≥ 20 min) → one span, fraction = 1260/3600.
        val gappy = (0..600).map { HrSample(deviceId = dev, ts = it.toLong(), bpm = 50) } +
            (1_860..3_600).map { HrSample(deviceId = dev, ts = it.toLong(), bpm = 50) } // gap 600→1860 = 1260 s
        val spans = SleepStager.offWristHRGapSpans(p, gappy)
        assertEquals(1, spans.size)
        assertEquals(600L, spans[0].first); assertEquals(1_860L, spans[0].second)
        assertEquals(1_260.0 / 3_600.0, SleepStager.offWristFraction(p, gappy, emptyList()), 1e-9)
        // Union must not double-count: a wrist-off interval overlapping the gap doesn't inflate coverage.
        assertEquals(
            1_260.0 / 3_600.0,
            SleepStager.offWristFraction(p, gappy, listOf(800L to 1_500L)), 1e-9,
        )
        // A disjoint wrist-off interval adds to coverage (union of 1260 s gap + 600 s event = 1860 s).
        assertEquals(
            1_860.0 / 3_600.0,
            SleepStager.offWristFraction(p, gappy, listOf(2_400L to 3_000L)), 1e-9,
        )
        // No HR stream at all → no gap spans, zero fraction (can't assert off-wrist without HR).
        assertTrue(SleepStager.offWristHRGapSpans(p, emptyList()).isEmpty())
        assertEquals(0.0, SleepStager.offWristFraction(p, emptyList(), emptyList()), 1e-9)
    }

    /**
     * #507 — the off-wrist HR-gap proxy must NOT drop a real night that simply has SPARSE heart rate
     * (a WHOOP 4.0's synced night is motion-reconstructed with thin, derived HR, so it's naturally full
     * of >20-min gaps). The density gate disables the proxy below one sample per [hrDenseSpacingS], so the
     * fraction is 0 and the night is kept — while explicit WRIST_OFF events remain authoritative. Twin of
     * Swift testSparseHRNightDisablesOffWristProxy_507.
     */
    @Test
    fun sparseHRNightDisablesOffWristProxy507() {
        val p = SleepStager.Period(stage = "sleep", start = 0L, end = 5_400L) // 90-min night
        // HR every 25 min → 4 samples, gaps of 1500 s (≥ 20 min): under the OLD logic almost entirely
        // "off-wrist". Density = 4 samples over a 4500 s span < 4500/600 = 7 ⇒ proxy disabled.
        val sparse = listOf(0L, 1_500L, 3_000L, 4_500L).map { HrSample(deviceId = dev, ts = it, bpm = 52) }
        assertTrue(
            "sparse HR (motion-reconstructed 4.0 night) must NOT register off-wrist gap spans",
            SleepStager.offWristHRGapSpans(p, sparse).isEmpty(),
        )
        assertEquals(
            "a sparse-HR real night must read 0% off-wrist, so it is never dropped (#507)",
            0.0, SleepStager.offWristFraction(p, sparse, emptyList()), 1e-9,
        )
        // An explicit WRIST_OFF interval still drops a genuinely off-wrist sparse night (events are
        // independent of the density gate): [0, 3000) over 5400 s = ~55% ≥ maxOffWristSleepFraction.
        assertTrue(
            "WRIST_OFF events remain authoritative regardless of HR density",
            SleepStager.offWristFraction(p, sparse, listOf(0L to 3_000L)) >= 0.5,
        )
    }
}
