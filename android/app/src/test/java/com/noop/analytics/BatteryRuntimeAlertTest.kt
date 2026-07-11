package com.noop.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Behaviour-identical twin of the Swift BatteryRuntimeAlertTests — same fixtures, same numbers. */
class BatteryRuntimeAlertTest {

    @Test
    fun firesAtThresholdAndArms() {
        val r = BatteryEstimator.runtimeAlert(remainingHours = 24.0, charging = false, alerted = false)
        assertTrue(r.fire)
        assertTrue(r.newAlerted)
    }

    @Test
    fun aboveThresholdNoFire() {
        val r = BatteryEstimator.runtimeAlert(remainingHours = 25.0, charging = false, alerted = false)
        assertFalse(r.fire)
        assertFalse(r.newAlerted)
    }

    @Test
    fun jitterInsideBandCannotRefire() {
        // Fired at 23h, estimate bounces 26 → 22 → 30 → 24: still armed-off, no second alert.
        var alerted = BatteryEstimator.runtimeAlert(23.0, charging = null, alerted = false).newAlerted
        assertTrue(alerted)
        for (hours in listOf(26.0, 22.0, 30.0, 24.0)) {
            val r = BatteryEstimator.runtimeAlert(hours, charging = null, alerted = alerted)
            assertFalse("re-fired at ${hours}h inside the hysteresis band", r.fire)
            alerted = r.newAlerted
        }
    }

    @Test
    fun rearmsOnGenuineRecoveryThenFiresNextCycle() {
        var alerted = BatteryEstimator.runtimeAlert(20.0, charging = null, alerted = false).newAlerted
        val recovered = BatteryEstimator.runtimeAlert(100.0, charging = null, alerted = alerted)
        assertFalse(recovered.fire)
        assertFalse(recovered.newAlerted)
        assertTrue(BatteryEstimator.runtimeAlert(24.0, charging = null, alerted = recovered.newAlerted).fire)
    }

    @Test
    fun confirmedChargingSuppressesButUnknownFires() {
        assertFalse(BatteryEstimator.runtimeAlert(10.0, charging = true, alerted = false).fire)
        assertTrue(BatteryEstimator.runtimeAlert(10.0, charging = null, alerted = false).fire)
    }

    @Test
    fun chargingSuppressionDoesNotArmGate() {
        // Suppressed while charging must NOT consume the once-per-cycle gate: unplug below the
        // threshold and the alert should still fire.
        val plugged = BatteryEstimator.runtimeAlert(10.0, charging = true, alerted = false)
        assertFalse(plugged.newAlerted)
        assertTrue(BatteryEstimator.runtimeAlert(10.0, charging = false, alerted = plugged.newAlerted).fire)
    }

    @Test
    fun rearmBoundaryIsInclusive() {
        assertFalse(BatteryEstimator.runtimeAlert(36.0, charging = null, alerted = true).newAlerted)
        assertTrue(BatteryEstimator.runtimeAlert(35.9, charging = null, alerted = true).newAlerted)
    }
}
