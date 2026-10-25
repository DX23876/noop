package com.noop.widget

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Pins the widget push-throttle contract, especially the #82 regression: with live HR streaming,
 * the first heart-rate sample must push IMMEDIATELY (key change), not wait out the refresh window —
 * and unchanged data must still refresh once per window so the displayed HR ticks along.
 */
class PushGateTests {

    private fun snap(
        recovery: Int? = null,
        rest: Int? = null,
        effort: Int? = null,
        hr: Int? = null,
        battery: Int? = null,
        connected: Boolean = true,
        at: Long = 0L,
    ) = WidgetSnapshot(
        recoveryPct = recovery,
        restPct = rest,
        effortPct = effort,
        heartRate = hr,
        batteryPct = battery,
        connected = connected,
        updatedAtMs = at,
    )

    @Before
    fun reset() = PushGate.resetForTest()

    @Test
    fun firstSnapshotIsAdmitted() {
        assertTrue(PushGate.admit(snap(at = 1_000)))
    }

    @Test
    fun unchangedSnapshotWithinWindowIsRejected() {
        PushGate.markPushed(snap(at = 1_000))
        assertFalse(PushGate.admit(snap(at = 2_000)))
    }

    @Test
    fun firstHeartRateSampleIsAdmittedImmediately() {
        // The #82 case: connect-era push had no HR; the moment HR starts streaming the widget must
        // update right away rather than sitting on "—" until the 60s refresh.
        PushGate.markPushed(snap(hr = null, at = 1_000))
        assertTrue(PushGate.admit(snap(hr = 72, at = 2_000)))
    }

    @Test
    fun hrValueChangeAloneWaitsForRefreshWindow() {
        PushGate.markPushed(snap(hr = 72, at = 1_000))
        assertFalse(PushGate.admit(snap(hr = 73, at = 2_000)))            // within window: rejected
        assertTrue(PushGate.admit(snap(hr = 73, at = 1_000 + 60_000)))    // window elapsed: admitted
    }

    @Test
    fun batteryIsBucketedInFivePercentSteps() {
        PushGate.markPushed(snap(battery = 80, at = 1_000))
        assertFalse(PushGate.admit(snap(battery = 82, at = 2_000)))  // same 5% bucket
        assertTrue(PushGate.admit(snap(battery = 86, at = 2_000)))   // bucket changed
    }

    @Test
    fun recoveryChangeIsAdmittedImmediately() {
        PushGate.markPushed(snap(recovery = null, at = 1_000))
        assertTrue(PushGate.admit(snap(recovery = 67, at = 2_000)))
    }

    @Test
    fun connectionFlipIsAdmittedImmediately() {
        PushGate.markPushed(snap(connected = true, at = 1_000))
        assertTrue(PushGate.admit(snap(connected = false, at = 2_000)))
    }

    // MARK: #516 — the 2x2 widget's Rest + Effort join the change-key so a freshly-scored score lands
    // immediately, exactly like recovery, rather than waiting out the 60s HR refresh window.

    @Test
    fun restScoreChangeIsAdmittedImmediately() {
        // Last night's Rest lands (null → scored) within the HR window: the widget must update at once.
        PushGate.markPushed(snap(rest = null, at = 1_000))
        assertTrue(PushGate.admit(snap(rest = 84, at = 2_000)))
    }

    @Test
    fun effortScoreChangeIsAdmittedImmediately() {
        // Effort climbing during the day is a meaningful change — admit straight away, don't wait 60s.
        PushGate.markPushed(snap(effort = 5, at = 1_000))
        assertTrue(PushGate.admit(snap(effort = 9, at = 2_000)))
    }

    @Test
    fun unchangedThreeScoreSnapshotWithinWindowIsStillRejected() {
        // With all three scores stable and inside the window, the gate still throttles (HR-only churn).
        PushGate.markPushed(snap(recovery = 60, rest = 80, effort = 12, hr = 70, at = 1_000))
        assertFalse(PushGate.admit(snap(recovery = 60, rest = 80, effort = 12, hr = 71, at = 2_000)))
    }
}
