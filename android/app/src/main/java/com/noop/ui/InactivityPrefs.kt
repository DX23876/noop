package com.noop.ui

import android.content.Context
import com.noop.analytics.SedentaryConfig
import com.noop.analytics.SedentaryDetector
import com.noop.analytics.SedentaryState

/**
 * InactivityPrefs — settings + persisted de-dup state for the inactivity reminder (#419).
 *
 * Mirrors the [NotifPrefs] idiom (flat SharedPreferences keys, getBool/getInt/getLong helpers) and
 * deliberately REUSES NotifPrefs for the global gates (master switch, quiet hours, only-when-worn)
 * rather than forking them. The inactivity-specific knobs are the threshold / re-nudge cadence / buzz
 * strength and the **active-hours window**, plus the small persisted de-dup state the live buzz path
 * carries between offloads.
 *
 * All gating + de-dup logic lives in the shipped, unit-tested [SedentaryDetector] engine. This file is
 * pure persistence: it materialises the user knobs + the reused NotifPrefs gates into a
 * [SedentaryConfig], rehydrates the [SedentaryState] (the LAST_* keys), and saves the engine's
 * `nextState` back. The active-hours window is evaluated by the engine against the candidate bout's
 * LOCAL end time, NOT `now` — gravity only reaches the app on the strap's offload flush, so an
 * overnight bout is processed in the morning; keying off the bout's own end time is what makes
 * "active hours excludes nighttime sleep" actually hold.
 */
object InactivityPrefs {
    private const val FILE = "noop_inactivity_prefs"

    const val ENABLED = "inactivity.enabled"
    const val THRESHOLD_MIN = "inactivity.thresholdMinutes"
    const val RENUDGE_MIN = "inactivity.reNudgeMinutes"
    const val BUZZ_LOOPS = "inactivity.buzzLoops"
    const val ACTIVE_HOURS_ENABLED = "inactivity.activeHoursEnabled"
    const val ACTIVE_START_MIN = "inactivity.activeStartMinutes"
    const val ACTIVE_END_MIN = "inactivity.activeEndMinutes"

    // De-dup / freshness state (persisted so a service/process restart can't re-buzz a replayed window).
    const val LAST_BUZZ_AT = "inactivity.lastBuzzAt"
    const val LAST_BUZZED_BOUT_START = "inactivity.lastBuzzedBoutStart"
    const val LAST_BUZZED_BOUT_END = "inactivity.lastBuzzedBoutEnd"
    const val LAST_PROCESSED_GRAVITY_TS = "inactivity.lastProcessedGravityTs"

    // Defaults (match SedentaryDetector / the PR #419 numbers).
    const val DEFAULT_THRESHOLD_MIN = SedentaryDetector.DEFAULT_THRESHOLD_MINUTES   // 45
    const val DEFAULT_RENUDGE_MIN = SedentaryDetector.DEFAULT_RENUDGE_MINUTES        // 30
    const val DEFAULT_BUZZ_LOOPS = SedentaryDetector.DEFAULT_BUZZ_LOOPS              // 2
    const val DEFAULT_ACTIVE_START_MIN = SedentaryDetector.DEFAULT_ACTIVE_START_MIN  // 09:00
    const val DEFAULT_ACTIVE_END_MIN = SedentaryDetector.DEFAULT_ACTIVE_END_MIN      // 17:00

    private fun prefs(ctx: Context) =
        ctx.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun getBool(ctx: Context, key: String, default: Boolean) = prefs(ctx).getBoolean(key, default)
    fun setBool(ctx: Context, key: String, value: Boolean) = prefs(ctx).edit().putBoolean(key, value).apply()
    fun getInt(ctx: Context, key: String, default: Int) = prefs(ctx).getInt(key, default)
    fun setInt(ctx: Context, key: String, value: Int) = prefs(ctx).edit().putInt(key, value).apply()
    fun getLong(ctx: Context, key: String, default: Long) = prefs(ctx).getLong(key, default)
    fun setLong(ctx: Context, key: String, value: Long) = prefs(ctx).edit().putLong(key, value).apply()

    fun enabled(ctx: Context) = getBool(ctx, ENABLED, false)
    fun thresholdMinutes(ctx: Context) = getInt(ctx, THRESHOLD_MIN, DEFAULT_THRESHOLD_MIN)
    fun reNudgeMinutes(ctx: Context) = getInt(ctx, RENUDGE_MIN, DEFAULT_RENUDGE_MIN)
    fun buzzLoops(ctx: Context) = getInt(ctx, BUZZ_LOOPS, DEFAULT_BUZZ_LOOPS)
    fun activeHoursEnabled(ctx: Context) = getBool(ctx, ACTIVE_HOURS_ENABLED, true)
    fun activeStartMinutes(ctx: Context) = getInt(ctx, ACTIVE_START_MIN, DEFAULT_ACTIVE_START_MIN)
    fun activeEndMinutes(ctx: Context) = getInt(ctx, ACTIVE_END_MIN, DEFAULT_ACTIVE_END_MIN)

    // ── Engine seams ─────────────────────────────────────────────────────────

    /**
     * Materialise the user knobs + the global gates reused from [NotifPrefs] into the engine's
     * [SedentaryConfig]. `worn` is supplied by the caller (the live BLE state); the engine applies the
     * only-when-worn gate. The detector tunables (move threshold / smoothing) keep the engine defaults.
     */
    fun config(ctx: Context): SedentaryConfig = SedentaryConfig(
        enabled = enabled(ctx),
        notificationsMasterOn = NotifPrefs.getBool(ctx, NotifPrefs.MASTER, false),
        thresholdMinutes = thresholdMinutes(ctx),
        reNudgeMinutes = reNudgeMinutes(ctx),
        buzzLoops = buzzLoops(ctx),
        activeHoursEnabled = activeHoursEnabled(ctx),
        activeStartMinutes = activeStartMinutes(ctx),
        activeEndMinutes = activeEndMinutes(ctx),
        quietHoursEnabled = NotifPrefs.getBool(ctx, NotifPrefs.QUIET, false),
        quietStartMinutes = NotifPrefs.getInt(ctx, NotifPrefs.QUIET_START, 22 * 60),
        quietEndMinutes = NotifPrefs.getInt(ctx, NotifPrefs.QUIET_END, 7 * 60),
        onlyWhenWorn = NotifPrefs.getBool(ctx, NotifPrefs.WORN, true),
    )

    /** Rehydrate the persisted de-dup state (the LAST_* keys) the engine feeds back into `evaluate`. */
    fun state(ctx: Context): SedentaryState = SedentaryState(
        lastProcessedGravityTs = getLong(ctx, LAST_PROCESSED_GRAVITY_TS, 0L),
        lastBuzzAt = getLong(ctx, LAST_BUZZ_AT, 0L),
        lastBuzzedBoutStart = getLong(ctx, LAST_BUZZED_BOUT_START, 0L),
        lastBuzzedBoutEnd = getLong(ctx, LAST_BUZZED_BOUT_END, 0L),
    )

    /** Persist the engine's `nextState` so a process/service restart can't re-buzz a replayed window. */
    fun saveState(ctx: Context, s: SedentaryState) {
        setLong(ctx, LAST_PROCESSED_GRAVITY_TS, s.lastProcessedGravityTs)
        setLong(ctx, LAST_BUZZ_AT, s.lastBuzzAt)
        setLong(ctx, LAST_BUZZED_BOUT_START, s.lastBuzzedBoutStart)
        setLong(ctx, LAST_BUZZED_BOUT_END, s.lastBuzzedBoutEnd)
    }

    /** Local tz offset (seconds east of UTC) at [epochSec] — the engine evaluates active/quiet hours
     *  against the bout's local end time, so it needs the offset for that instant (DST-correct). */
    fun tzOffsetSec(epochSec: Long): Long =
        java.util.TimeZone.getDefault().getOffset(epochSec * 1000L) / 1000L
}
