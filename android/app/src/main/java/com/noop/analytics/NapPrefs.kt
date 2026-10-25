package com.noop.analytics

import android.content.Context

/**
 * NapPrefs — the small on-device pref surface for on-device short-nap detection (reimplemented from
 * @cbarrado's PR #569 under NoopApp identity). Single toggle plus the conservative thresholds, all
 * opt-in / manual-first (the feature defaults OFF). SharedPreferences-backed via the shared "noop_prefs"
 * store, single-user, on-device — nothing here leaves the device.
 *
 * Kept tiny and dependency-free (Context only) so the BLE-layer hook can read [config] without pulling in
 * the UI layer, exactly like the inactivity reminder reads InactivityPrefs. The Automations screen writes
 * the same key. Key strings MATCH the macOS twin so the platforms read consistent prefs.
 */
object NapPrefs {

    private const val PREFS = "noop_prefs"
    private const val KEY_ENABLED = "noop.napDetectionEnabled"
    private const val KEY_HIGH_WATER = "noop.napHighWaterTs"

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Feature toggle (default OFF — opt-in, manual-first). */
    fun enabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun setEnabled(context: Context, on: Boolean) =
        prefs(context).edit().putBoolean(KEY_ENABLED, on).apply()

    /**
     * High-water mark (unix seconds): a nap whose window ENDS at/before this was already past when nap
     * detection first ran, so it must NOT be surfaced — otherwise a fresh install with a deep history
     * backlog would dredge up days of old afternoon naps on the first offload. Seeded to "now" on the
     * FIRST read (so only naps that happen AFTER enabling are offered); advanced as windows are judged.
     * 0 = never seeded.
     */
    fun highWaterTs(context: Context): Long = prefs(context).getLong(KEY_HIGH_WATER, 0L)

    fun setHighWaterTs(context: Context, ts: Long) =
        prefs(context).edit().putLong(KEY_HIGH_WATER, ts).apply()

    /**
     * Return the effective high-water mark, seeding it to [nowSec] the first time it's read (so the very
     * first offload after enabling can't surface historical naps). Idempotent once seeded.
     */
    fun highWaterOrSeed(context: Context, nowSec: Long): Long {
        val existing = highWaterTs(context)
        if (existing > 0L) return existing
        setHighWaterTs(context, nowSec)
        return nowSec
    }

    /** Build the engine config from the persisted toggle for the central offload hook. Thresholds use the
     *  engine defaults (no per-user UI for them yet — keep parity with macOS's fixed NapConfig). */
    fun config(context: Context): NapConfig = NapConfig(enabled = enabled(context))
}
