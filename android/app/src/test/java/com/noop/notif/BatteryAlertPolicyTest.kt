package com.noop.notif

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for [BatteryAlertPolicy], the pure once-per-crossing gate behind the strap low/full
 * battery notifications (#368). The two `*Alerted` flags are PERSISTED, so the policy must be a
 * deterministic function of (pct, charging, lowAlerted, fullAlerted) with no hidden state — that's
 * what lets a battery hovering near a threshold fire exactly once per discharge cycle even across
 * a process restart. Mirrors the macOS BatteryAlertPolicy tests byte-for-byte.
 */
class BatteryAlertPolicyTest {

    /** 1. Cross down to ≤15% fires low once; a further reading below 15% with the flag set does not.
     *  (16% is still above the 15% threshold, so nothing fires there — the genuine crossing is ≤15.) */
    @Test
    fun crossDownFiresLowThenDoesNotRefire() {
        // 16% — above the threshold, no alert yet, flag stays clear.
        val above = BatteryAlertPolicy.evaluate(pct = 16, charging = null, lowAlerted = false, fullAlerted = false)
        assertFalse(above.fireLow)
        assertFalse(above.fireFull)
        assertFalse(above.newLowAlerted)

        // 14% — first reading at/under the threshold → fires once and latches the flag.
        val crossed = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = above.newLowAlerted, fullAlerted = false)
        assertTrue(crossed.fireLow)
        assertTrue(crossed.newLowAlerted)

        // 14% again with the flag persisted true → no re-fire.
        val again = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = crossed.newLowAlerted, fullAlerted = false)
        assertFalse(again.fireLow)
        assertTrue(again.newLowAlerted)
    }

    /** 2. Jitter (15→14→15→14) fires low only once; it re-arms only once pct ≥ 25. */
    @Test
    fun jitterNearThresholdFiresOnce() {
        var low = false
        // 15 ≤ 15 threshold → fires.
        val a = BatteryAlertPolicy.evaluate(pct = 15, charging = null, lowAlerted = low, fullAlerted = false)
        assertTrue(a.fireLow); low = a.newLowAlerted
        // 14 — already alerted, no re-fire.
        val b = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(b.fireLow); low = b.newLowAlerted
        // bounce back to 15 — still under the 25% re-arm band, stays armed-off.
        val c = BatteryAlertPolicy.evaluate(pct = 15, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(c.fireLow); low = c.newLowAlerted
        // 14 again — still no re-fire.
        val d = BatteryAlertPolicy.evaluate(pct = 14, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(d.fireLow); low = d.newLowAlerted
        assertTrue(low)
    }

    /** 3. Recharge to ≥25 re-arms the low flag, then dropping back to ≤15 fires again. */
    @Test
    fun rechargeAbove25RearmsThenFiresAgain() {
        // Fire once.
        val fired = BatteryAlertPolicy.evaluate(pct = 12, charging = null, lowAlerted = false, fullAlerted = false)
        assertTrue(fired.fireLow)
        // Climb to 25% — re-arms (newLowAlerted false), nothing fires.
        val rearmed = BatteryAlertPolicy.evaluate(pct = 25, charging = null, lowAlerted = fired.newLowAlerted, fullAlerted = false)
        assertFalse(rearmed.fireLow)
        assertFalse(rearmed.newLowAlerted)
        // Drop to 10% — fires again now the flag is clear.
        val refired = BatteryAlertPolicy.evaluate(pct = 10, charging = null, lowAlerted = rearmed.newLowAlerted, fullAlerted = false)
        assertTrue(refired.fireLow)
    }

    /** 4. charging == true suppresses the low alert even at 10%, and (#80) does NOT re-arm — an
     *  already-alerted flag stays set so the charge bit flickering to null can't re-fire it. */
    @Test
    fun chargingSuppressesLowWithoutRearming() {
        val r = BatteryAlertPolicy.evaluate(pct = 10, charging = true, lowAlerted = true, fullAlerted = false)
        assertFalse(r.fireLow)
        // #80: charging must NOT re-arm. It used to zero the flag here, and the next null-charging read then
        // re-fired the alert WHILE charging. The already-alerted flag now stays set.
        assertTrue(r.newLowAlerted)
    }

    /** 4b. (#80) The strap reports its charge bit only every ~8 min, so it flickers true→null. While low,
     *  a charging read followed by a null read must NOT re-fire the low alert. */
    @Test
    fun chargeBitFlickerToNullDoesNotRefireLow() {
        var low = true   // low alert already fired (before plugging in, or on the first not-charging read)
        val charging = BatteryAlertPolicy.evaluate(pct = 12, charging = true, lowAlerted = low, fullAlerted = false)
        assertFalse(charging.fireLow); low = charging.newLowAlerted
        // Next BATTERY_LEVEL event hasn't landed yet → charge state unknown. Must stay silent.
        val gap = BatteryAlertPolicy.evaluate(pct = 12, charging = null, lowAlerted = low, fullAlerted = false)
        assertFalse(gap.fireLow)   // was `true` before the #80 fix
    }

    /** 5. Full fires once at 100; stays armed until pct drops below 100, then 100 again re-fires. */
    @Test
    fun fullFiresOncePerChargeCycle() {
        val first = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = false)
        assertTrue(first.fireFull)
        assertTrue(first.newFullAlerted)
        // Still 100 with the flag set → no re-fire.
        val again = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = true)
        assertFalse(again.fireFull)
        assertTrue(again.newFullAlerted)
        // Drop below 100 → re-arms.
        val dropped = BatteryAlertPolicy.evaluate(pct = 97, charging = null, lowAlerted = false, fullAlerted = true)
        assertFalse(dropped.fireFull)
        assertFalse(dropped.newFullAlerted)
        // Back to 100 → fires again.
        val refired = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = dropped.newFullAlerted)
        assertTrue(refired.fireFull)
    }

    /** 6. (#514) Dropping below 100 while the full alert stands signals clearFull exactly once, so
     *  the notifier can pull the stale "fully charged" note. It does not touch the low alert. */
    @Test
    fun dropBelowFullClearsStaleFullNote() {
        // Standing full alert drops to 99% → clearFull, re-arms, nothing fires.
        val drop = BatteryAlertPolicy.evaluate(pct = 99, charging = null, lowAlerted = false, fullAlerted = true)
        assertTrue(drop.clearFull)
        assertFalse(drop.fireFull)
        assertFalse(drop.fireLow)
        assertFalse(drop.newFullAlerted)

        // Next reading below 100 with the flag already re-armed does not keep asking to clear.
        val next = BatteryAlertPolicy.evaluate(pct = 90, charging = null, lowAlerted = drop.newLowAlerted, fullAlerted = drop.newFullAlerted)
        assertFalse(next.clearFull)
    }

    /** 7. (#514) Holding at 100 (full standing) must NOT clear, and a fresh fire at 100 from a clean
     *  state must NOT clear — clearFull is the below-100 transition only. */
    @Test
    fun holdingAtFullDoesNotClear() {
        val hold = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = true)
        assertFalse(hold.clearFull)

        val fresh = BatteryAlertPolicy.evaluate(pct = 100, charging = null, lowAlerted = false, fullAlerted = false)
        assertTrue(fresh.fireFull)
        assertFalse(fresh.clearFull)
    }
}
