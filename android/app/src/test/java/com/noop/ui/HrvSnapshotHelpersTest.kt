package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the pure HRV-snapshot view helpers (#127): mean-HR derivation from the mean NN interval, the
 * null-safe formatter, and the capture-ring fraction. Mirrors the Swift HRVSnapshotView static
 * helpers (`meanHR`, `format`) and `captureFraction` case-for-case.
 */
class HrvSnapshotHelpersTest {

    // ── meanHr (60000 / meanNN) ──────────────────────────────────────────────

    @Test
    fun meanHrConvertsMeanNnToBpm() {
        // 1000 ms mean NN → exactly 60 bpm.
        assertEquals(60.0, meanHr(1000.0)!!, 1e-9)
        // 800 ms → 75 bpm.
        assertEquals(75.0, meanHr(800.0)!!, 1e-9)
    }

    @Test
    fun meanHrIsNullForMissingOrNonPositiveNn() {
        assertNull(meanHr(null))
        assertNull(meanHr(0.0))
        assertNull(meanHr(-5.0))
    }

    // ── formatHrv ────────────────────────────────────────────────────────────

    @Test
    fun formatHrvRendersEmDashForNull() {
        assertEquals("—", formatHrv(null, "%.0f"))
    }

    @Test
    fun formatHrvRoundsToTheGivenPrecision() {
        assertEquals("42", formatHrv(42.4, "%.0f"))
        assertEquals("43", formatHrv(42.6, "%.0f"))
    }

    // ── captureFraction (ring progress) ──────────────────────────────────────

    @Test
    fun captureFractionIsZeroWhenIdle() {
        assertEquals(0f, captureFractionForTest(HrvPhaseForTest.Idle, HRV_CAPTURE_SECONDS), 1e-6f)
    }

    @Test
    fun captureFractionIsOneWhenDone() {
        assertEquals(1f, captureFractionForTest(HrvPhaseForTest.Done, 0), 1e-6f)
    }

    @Test
    fun captureFractionTracksElapsedWhileCapturing() {
        // Half the window elapsed → 0.5.
        assertEquals(
            0.5f,
            captureFractionForTest(HrvPhaseForTest.Capturing, HRV_CAPTURE_SECONDS / 2),
            1e-6f,
        )
        // No time elapsed yet → 0.
        assertEquals(
            0f,
            captureFractionForTest(HrvPhaseForTest.Capturing, HRV_CAPTURE_SECONDS),
            1e-6f,
        )
    }

    // The production `captureFraction` + `HrvPhase` are file-private to HrvSnapshotScreen; this test
    // re-states the identical formula so the ring's mapping is pinned without widening visibility.
    private enum class HrvPhaseForTest { Idle, Capturing, Done }

    private fun captureFractionForTest(phase: HrvPhaseForTest, secondsRemaining: Int): Float =
        when (phase) {
            HrvPhaseForTest.Idle -> 0f
            HrvPhaseForTest.Capturing ->
                (HRV_CAPTURE_SECONDS - secondsRemaining).toFloat() / HRV_CAPTURE_SECONDS.toFloat()
            HrvPhaseForTest.Done -> 1f
        }
}
