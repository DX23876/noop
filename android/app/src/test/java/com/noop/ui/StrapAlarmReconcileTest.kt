package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone

/**
 * The strap has ONE firmware-alarm slot, but two features want it (#5): the "Strap wake-alarm"
 * (smart alarm) and the "Buzz WHOOP 4/5" companion. Before the fix each armed/disarmed the slot
 * independently, so toggling one OFF disarmed a slot the other still wanted (the clobber), and
 * whichever ran last won the time.
 *
 * [reconcileStrapAlarm] in AppViewModel is now the sole arm/disarm caller; its decision is the pure
 * [earliestStrapAlarmEpochSec] over each feature's requested epoch. BOTH now resolve through
 * [nextSmartAlarmEpochSec]: the companion arms the strap at the PHONE alarm's time, so once the phone
 * alarm gained its own weekday selection the companion had to honour it too, or the band would buzz on
 * a morning that alarm is switched off. It passes no per-day overrides — the phone alarm has none.
 * These tests exercise that pure decision against a fixed clock, no BLE stack needed.
 * Calendar.DAY_OF_WEEK: 1 = Sun ... 7 = Sat.
 */
class StrapAlarmReconcileTest {

    private val utc = TimeZone.getTimeZone("UTC")
    private fun utcCalendar(): Calendar = Calendar.getInstance(utc)

    private fun ms(year: Int, month1: Int, day: Int, hour: Int, minute: Int): Long =
        utcCalendar().apply { clear(); set(year, month1 - 1, day, hour, minute, 0) }.timeInMillis

    // 2026-06-17 is a Wednesday (DAY_OF_WEEK 4).
    private fun wedAt(hour: Int, minute: Int) = ms(2026, 6, 17, hour, minute)

    /** The smart alarm's requested epoch when ENABLED, else null (mirrors reconcileStrapAlarm). */
    private fun smartReq(enabled: Boolean, minuteOfDay: Int, weekdays: Set<Int>, nowMs: Long): Long? =
        if (enabled) nextSmartAlarmEpochSec(minuteOfDay, weekdays, nowMs, ::utcCalendar) else null

    /** The Buzz-WHOOP companion's requested epoch when ENABLED, else null. Mirrors reconcileStrapAlarm:
     *  weekday-aware against the PHONE alarm's days, empty meaning every day. */
    private fun buzzReq(
        enabled: Boolean,
        minuteOfDay: Int,
        nowMs: Long,
        weekdays: Set<Int> = emptySet(),
    ): Long? = if (enabled) nextSmartAlarmEpochSec(minuteOfDay, weekdays, nowMs, ::utcCalendar) else null

    @Test
    fun bothOff_disarms() {
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(false, 7 * 60, emptySet(), now),
            buzzReq(false, 8 * 60, now),
        )
        assertNull(slot)
    }

    @Test
    fun onlySmartOn_armsToSmartTime() {
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(true, 7 * 60, emptySet(), now),   // 07:00
            buzzReq(false, 8 * 60, now),
        )
        assertEquals(wedAt(7, 0) / 1000, slot)
    }

    @Test
    fun onlyBuzzOn_armsToBuzzTime() {
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(false, 7 * 60, emptySet(), now),
            buzzReq(true, 8 * 60, now),                 // 08:00
        )
        assertEquals(wedAt(8, 0) / 1000, slot)
    }

    @Test
    fun bothOn_armsToEarliest() {
        val now = wedAt(6, 0)
        // Smart 07:00, Buzz 08:00 -> earliest is the smart 07:00.
        val slot = earliestStrapAlarmEpochSec(
            smartReq(true, 7 * 60, emptySet(), now),
            buzzReq(true, 8 * 60, now),
        )
        assertEquals(wedAt(7, 0) / 1000, slot)
    }

    @Test
    fun bothOn_thenTurnBuzzOff_slotStaysArmedToSmart() {
        // THE CLOBBER SCENARIO. Start with both on; the slot is armed to the earlier (smart 06:30).
        val now = wedAt(6, 0)
        val smartMin = 6 * 60 + 30   // 06:30
        val buzzMin = 8 * 60         // 08:00
        val bothOn = earliestStrapAlarmEpochSec(
            smartReq(true, smartMin, emptySet(), now),
            buzzReq(true, buzzMin, now),
        )
        assertEquals(wedAt(6, 30) / 1000, bothOn)

        // Now turn Buzz OFF. The OLD code unconditionally disarmed here, killing the smart alarm. The
        // reconciler instead re-evaluates BOTH flags: smart is still on, so the slot stays armed to 06:30.
        val afterBuzzOff = earliestStrapAlarmEpochSec(
            smartReq(true, smartMin, emptySet(), now),
            buzzReq(false, buzzMin, now),
        )
        assertEquals("smart alarm must survive turning Buzz off", wedAt(6, 30) / 1000, afterBuzzOff)
    }

    @Test
    fun bothOn_thenTurnSmartOff_slotStaysArmedToBuzz() {
        // Mirror of the clobber the other way: turning the smart alarm OFF must leave the Buzz companion's
        // slot armed (the old smart-off path called disableStrapAlarm() unconditionally).
        val now = wedAt(6, 0)
        val smartMin = 6 * 60 + 30   // 06:30
        val buzzMin = 8 * 60         // 08:00
        val afterSmartOff = earliestStrapAlarmEpochSec(
            smartReq(false, smartMin, emptySet(), now),
            buzzReq(true, buzzMin, now),
        )
        assertEquals("Buzz must survive turning the smart alarm off", wedAt(8, 0) / 1000, afterSmartOff)
    }

    @Test
    fun bothOn_buzzEarlier_armsToBuzz() {
        // When the companion is the earlier of the two, the slot takes ITS time.
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(true, 9 * 60, emptySet(), now),   // smart 09:00
            buzzReq(true, 7 * 60, now),                 // buzz 07:00 (earlier)
        )
        assertEquals(wedAt(7, 0) / 1000, slot)
    }

    @Test
    fun smartOnButCorruptedWeekdays_fallsBackToBuzz() {
        // Smart is "on" but its weekday set has no valid day (nextSmartAlarmEpochSec returns null), so the
        // slot must fall through to the Buzz companion rather than disarming.
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(true, 7 * 60, setOf(0, 8), now),   // no valid firing day -> null
            buzzReq(true, 8 * 60, now),
        )
        assertEquals(wedAt(8, 0) / 1000, slot)
    }

    @Test
    fun companionDailySchedule_rollsToTomorrowWhenPassed() {
        // Companion fires every day; a time already passed today rolls to tomorrow.
        val now = wedAt(9, 0)
        val slot = buzzReq(true, 8 * 60, now)  // 08:00, already passed
        assertEquals(ms(2026, 6, 18, 8, 0) / 1000, slot)         // Thu 08:00
    }

    @Test
    fun dailyScheduleCoversEveryWakeMinuteAndRequiresAStrictlyFutureFire() {
        val start = 1_781_654_400L // 2026-06-17 00:00 UTC
        val now = 1_781_699_696L   // 2026-06-17 12:34:56 UTC
        for (minute in 0 until 1440) {
            val today = start + minute * 60L
            val expected = if (today <= now) today + 86_400L else today
            assertEquals("minute $minute", expected, buzzReq(true, minute, now * 1000))
            assertEquals(
                "exact wake minute $minute must roll to tomorrow",
                today + 86_400L,
                buzzReq(true, minute, today * 1000),
            )
        }
    }

    // DST epochs are the standalone Swift production scheduler oracle output, pinned on both sides.
    @Test
    fun dailySpringRolloverKeepsLocalWakeTimeAcrossTheShortDay() {
        val factory = { Calendar.getInstance(TimeZone.getTimeZone("America/Chicago")) }
        val now = 1_772_892_000L // 2026-03-07 08:00 CST
        val expected = 1772974800L // 2026-03-08 08:00 CDT, 23 hours later
        assertEquals(expected, nextSmartAlarmEpochSec(8 * 60, emptySet(), now * 1000, factory))
        assertEquals(23 * 3600L, expected - now)
    }

    @Test
    fun dailyAutumnRolloverKeepsLocalWakeTimeAcrossTheLongDay() {
        val factory = { Calendar.getInstance(TimeZone.getTimeZone("America/Chicago")) }
        val now = 1_793_451_600L // 2026-10-31 08:00 CDT
        val expected = 1793541600L // 2026-11-01 08:00 CST, 25 hours later
        assertEquals(expected, nextSmartAlarmEpochSec(8 * 60, emptySet(), now * 1000, factory))
        assertEquals(25 * 3600L, expected - now)
    }

    /**
     * The phone alarm's weekday selection must reach the COMPANION too. "Buzz WHOOP 4" arms the band at
     * the phone alarm's earliest wake time, so a day switched off there must not leave the strap buzzing
     * on that morning — the day the user specifically asked to sleep through.
     *
     * Wednesday 06:00 "now", companion wanting 08:00, but the phone alarm set to Thursday only: the slot
     * must land on THURSDAY 08:00, not today.
     */
    @Test
    fun companionHonoursThePhoneAlarmsWeekdays() {
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(false, 7 * 60, emptySet(), now),
            buzzReq(true, 8 * 60, now, weekdays = setOf(Calendar.THURSDAY)),
        )
        assertEquals(ms(2026, 6, 18, 8, 0) / 1000, slot)
    }

    /** …and an EMPTY selection still means every day, so the pre-weekday behaviour is untouched: the
     *  companion takes TODAY at 08:00, exactly as the old daily resolver did. */
    @Test
    fun companionWithNoWeekdaysStillFiresToday() {
        val now = wedAt(6, 0)
        val slot = earliestStrapAlarmEpochSec(
            smartReq(false, 7 * 60, emptySet(), now),
            buzzReq(true, 8 * 60, now),
        )
        assertEquals(wedAt(8, 0) / 1000, slot)
    }
}
