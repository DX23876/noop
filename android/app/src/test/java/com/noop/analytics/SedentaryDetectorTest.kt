package com.noop.analytics

import com.noop.data.GravitySample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [SedentaryDetector] — the pure core of the inactivity reminder. The detection tests mirror
 * the Swift SedentaryDetectorTests; the decision tests cover the live-path guard (fires after the
 * threshold; not inside cooldown; not outside active hours; resets on movement; respects the toggle).
 * Fixtures are IDENTICAL to SedentaryDetectorTests.swift so the two engines prove byte-identical output.
 */
class SedentaryDetectorTest {

    private val dev = "test-device"

    // Cadence ~3 s (close to real offload data) so the 240 s smoothing window behaves realistically.
    private val cad = 3L

    /** A sample at second [sec] with gravity (x, 0, 1). */
    private fun gravS(sec: Long, x: Double) =
        GravitySample(deviceId = dev, ts = sec, x = x, y = 0.0, z = 1.0)

    // ── Detection (ActivityDetector parity) ───────────────────────────────────

    @Test fun emptyOrSingle_yieldsNothing() {
        assertTrue(SedentaryDetector.detectSedentaryBouts(emptyList()).isEmpty())
        assertTrue(SedentaryDetector.detectSedentaryBouts(listOf(gravS(0, 0.0))).isEmpty())
    }

    @Test fun sittingThenWalking_yieldsOneBoutEndingAtTheWalk() {
        val g = ArrayList<GravitySample>()
        var t = 0L
        // 30 min "sitting": tiny wrist motion (~0.02 g deltas) — below the move threshold.
        while (t <= 30 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        // then 8 min "walking": large sustained deltas (~0.5 g) — above the threshold.
        while (t <= 38 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.5)); t += cad }

        val bouts = SedentaryDetector.detectSedentaryBouts(g)
        assertEquals(1, bouts.size)
        assertEquals(0L, bouts[0].start)
        // Bout ends shortly after the sit→walk boundary (the smoothed signal takes ~1–2 min to cross).
        assertTrue("bout should end ~30min, got ${bouts[0].end / 60}", bouts[0].end in 27 * 60L..34 * 60L)
    }

    @Test fun isolatedReachesDoNotFragmentIt() {
        // Mostly tiny motion with two isolated big "reaches" — the smoothed signal averages them down,
        // so the sedentary bout stays whole (reaching for coffee shouldn't reset the timer).
        val g = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) {
            val reach = t == 10 * 60L || t == 20 * 60L
            g.add(gravS(t, if (reach) 1.0 else if ((t / cad) % 2 == 0L) 0.0 else 0.02))
            t += cad
        }
        assertEquals("isolated reaches shouldn't fragment the sedentary bout", 1, SedentaryDetector.detectSedentaryBouts(g).size)
    }

    @Test fun continuousWalking_yieldsNothing() {
        val g = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.5)); t += cad }
        assertTrue("continuous walking is never sedentary", SedentaryDetector.detectSedentaryBouts(g).isEmpty())
    }

    @Test fun shortStretchUnderMinMinutes_dropped() {
        // ~10 min sitting then walking → under the 15-min detector default → no bout.
        val g = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 10 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        while (t <= 20 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.5)); t += cad }
        assertTrue("a <15min stretch shouldn't count", SedentaryDetector.detectSedentaryBouts(g).isEmpty())
    }

    // ── Pure time helpers (InactivityPrefs parity) ────────────────────────────

    /** epochSec for `hour:min` local when tz offset is 0. */
    private fun atLocal(hour: Int, min: Int = 0) = (hour * 3600L + min * 60L)

    @Test fun localMinuteOfDay_mapsInstantToLocalMinute() {
        assertEquals(8 * 60, SedentaryDetector.localMinuteOfDay(atLocal(8), tzOffsetSec = 0))
        assertEquals(14 * 60, SedentaryDetector.localMinuteOfDay(atLocal(14), tzOffsetSec = 0))
        // A UTC 08:00 instant in UTC+1 reads as 09:00 local.
        assertEquals(9 * 60, SedentaryDetector.localMinuteOfDay(atLocal(8), tzOffsetSec = 3600))
        // Negative offset wraps correctly (UTC 00:30 in UTC-1 → 23:30 the previous local day).
        assertEquals(23 * 60 + 30, SedentaryDetector.localMinuteOfDay(atLocal(0, 30), tzOffsetSec = -3600))
    }

    @Test fun windowContains_handlesWrapAround() {
        // 9–17 straight window.
        assertTrue(SedentaryDetector.windowContains(14 * 60, 9 * 60, 17 * 60))
        assertFalse(SedentaryDetector.windowContains(8 * 60, 9 * 60, 17 * 60))
        // 22:00–07:00 window (crosses midnight): 23:00 inside, 10:00 outside.
        assertTrue(SedentaryDetector.windowContains(23 * 60, 22 * 60, 7 * 60))
        assertFalse(SedentaryDetector.windowContains(10 * 60, 22 * 60, 7 * 60))
    }

    // ── Decision / live-path guard ─────────────────────────────────────────────

    @Test fun firesAfterIdleThreshold() {
        // 30 min of pure sitting → a single ≥15-min bout ending at the newest sample (still seated).
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true,
            thresholdMinutes = 15, reNudgeMinutes = 30, buzzLoops = 3,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertTrue("a 30-min current sedentary bout past the 15-min threshold should buzz", d.shouldBuzz)
        assertEquals(3, d.buzzLoops)
        assertEquals(newest, d.nextState.lastBuzzAt)
        assertEquals(0L, d.nextState.lastBuzzedBoutStart)
        assertEquals(newest, d.nextState.lastProcessedGravityTs)
    }

    @Test fun doesNotFireUnderThreshold() {
        // 10 min sitting < 15-min threshold → no bout → no buzz.
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 10 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse(d.shouldBuzz)
    }

    @Test fun doesNotFireInsideCooldown() {
        // Same continuing bout buzzed 10 min ago; re-nudge is 30 min → still in cooldown → no buzz.
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15, reNudgeMinutes = 30,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        // Last buzz 10 min before now, for THIS bout (start 0 ≤ lastBuzzedBoutEnd, so it "continues").
        val prior = SedentaryState(lastProcessedGravityTs = 0, lastBuzzAt = newest - 10 * 60, lastBuzzedBoutStart = 0, lastBuzzedBoutEnd = newest)
        val d = SedentaryDetector.evaluate(sit, prior, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("still inside the 30-min re-nudge cooldown", d.shouldBuzz)

        // ...but 31 min later the same bout re-nudges.
        val later = SedentaryState(lastProcessedGravityTs = 0, lastBuzzAt = newest - 31 * 60, lastBuzzedBoutStart = 0, lastBuzzedBoutEnd = newest)
        val d2 = SedentaryDetector.evaluate(sit, later, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertTrue("past the re-nudge cadence the continuing bout buzzes again", d2.shouldBuzz)
    }

    @Test fun doesNotFireOutsideActiveHours() {
        // A 30-min bout whose end maps to 08:00 local; active window is 09:00–17:00 → excluded.
        val base = atLocal(7, 30)
        val sit = ArrayList<GravitySample>()
        var t = base
        while (t <= base + 30 * 60) { sit.add(gravS(t, if (((t - base) / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts } // == 08:00 local
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = true, activeStartMinutes = 9 * 60, activeEndMinutes = 17 * 60,
            quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("a bout ending 08:00 is outside the 09:00–17:00 active window", d.shouldBuzz)

        // Same shape anchored to 14:00 IS inside the window → buzzes.
        val base2 = atLocal(13, 30)
        val sit2 = ArrayList<GravitySample>()
        var t2 = base2
        while (t2 <= base2 + 30 * 60) { sit2.add(gravS(t2, if (((t2 - base2) / cad) % 2 == 0L) 0.0 else 0.02)); t2 += cad }
        val newest2 = sit2.maxOf { it.ts } // == 14:00 local
        val d2 = SedentaryDetector.evaluate(sit2, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest2, tzOffsetSec = 0)
        assertTrue("a bout ending 14:00 is inside the active window", d2.shouldBuzz)
    }

    @Test fun resetsOnDetectedMovement() {
        // The bout ended (the user walked), so its end is far behind the newest sample → not current.
        // 30 min sitting then a 25-min walk; newest is at the end of the walk, gap (newest - boutEnd)
        // > 20-min maxGapS → stale → no buzz.
        val g = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        while (t <= 55 * 60) { g.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.5)); t += cad }
        val newest = g.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(g, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("the user got up and walked — the stale bout must not re-buzz", d.shouldBuzz)
    }

    @Test fun respectsDisabledFlag() {
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = false, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("disabled → never buzz", d.shouldBuzz)
        assertEquals("disabled leaves state untouched", SedentaryState.INITIAL, d.nextState)
    }

    @Test fun respectsNotificationMasterOff() {
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = false, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("master notification switch off → inert", d.shouldBuzz)
    }

    @Test fun respectsOnlyWhenWorn() {
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = true,
        )
        val d = SedentaryDetector.evaluate(sit, SedentaryState.INITIAL, cfg, worn = false, nowSec = newest, tzOffsetSec = 0)
        assertFalse("only-when-worn on + strap off → no buzz", d.shouldBuzz)
    }

    @Test fun replayedOffloadDoesNotReBuzz() {
        // The newest gravity ts hasn't advanced past lastProcessedGravityTs → a no-op (idempotent sync).
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        val prior = SedentaryState(lastProcessedGravityTs = newest)
        val d = SedentaryDetector.evaluate(sit, prior, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertFalse("a replayed / no-new-rows offload can't re-buzz", d.shouldBuzz)
        assertEquals("no advance → state unchanged", prior, d.nextState)
    }

    @Test fun newBoutAfterMovementAlertsImmediately() {
        // A fresh, distinct bout (starts after the last buzzed bout's end) alerts even within the
        // re-nudge window, because it is NOT a continuation.
        val sit = ArrayList<GravitySample>()
        var t = 0L
        while (t <= 30 * 60) { sit.add(gravS(t, if ((t / cad) % 2 == 0L) 0.0 else 0.02)); t += cad }
        val newest = sit.maxOf { it.ts }
        val cfg = SedentaryConfig(
            enabled = true, notificationsMasterOn = true, thresholdMinutes = 15, reNudgeMinutes = 30,
            activeHoursEnabled = false, quietHoursEnabled = false, onlyWhenWorn = false,
        )
        // Last buzz was 5 min ago but for a PRIOR bout that ended before this one started (ts 0).
        val prior = SedentaryState(lastProcessedGravityTs = 0, lastBuzzAt = newest - 5 * 60, lastBuzzedBoutStart = -1000, lastBuzzedBoutEnd = -1)
        val d = SedentaryDetector.evaluate(sit, prior, cfg, worn = true, nowSec = newest, tzOffsetSec = 0)
        assertTrue("a distinct new bout alerts on its own crossing, ignoring cooldown", d.shouldBuzz)
    }
}
