package com.noop.ui

import android.content.Context
import com.noop.core.CoreAlerts
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), Android Settings parity: the heart-rate ceiling the wearer sets under Strap Actions › Haptic coaching.
 * The keys and defaults are the iPhone's (`BehaviorStore`): the switch is the preference that used to read "HR-zone
 * coaching" (`NoopPrefs.zoneCoaching`), and with the default ceiling (the start of Zone 5) it fires where that did.
 * The rules (the ceiling, when to warn, repeat and confirm the recovery) are the core's `alerts.hrCeiling`.
 */
object HrCeilingPrefs {
    const val ZONE = "zone"
    const val BPM = "bpm"
    const val ALWAYS = "always"
    const val WORKOUT = "workout"
    const val STANDARD = "standard"
    const val EVERY_TWO_SECONDS = "everyTwoSeconds"

    private const val KEY_MODE = "behavior.hrCeilingThresholdMode"
    private const val KEY_ZONE = "behavior.hrCeilingAllowedZone"
    private const val KEY_BPM = "behavior.hrCeilingBPM"
    private const val KEY_SCOPE = "behavior.hrCeilingScope"
    private const val KEY_REMINDER = "behavior.hrCeilingReminderMode"

    private fun p(ctx: Context) = NoopPrefs.of(ctx)

    /** Profile zone or a fixed value. */
    fun mode(ctx: Context): String = p(ctx).getString(KEY_MODE, ZONE).takeIf { it == BPM } ?: ZONE
    fun setMode(ctx: Context, value: String) = p(ctx).edit().putString(KEY_MODE, value).apply()

    /** The highest zone allowed, 1 to 4; the ceiling is the start of the zone above it. */
    fun allowedZone(ctx: Context): Int = p(ctx).getInt(KEY_ZONE, 4).coerceIn(1, 4)
    fun setAllowedZone(ctx: Context, value: Int) = p(ctx).edit().putInt(KEY_ZONE, value.coerceIn(1, 4)).apply()

    /** The fixed ceiling in bpm, 40 to 220. */
    fun fixedBpm(ctx: Context): Int = p(ctx).getInt(KEY_BPM, 150).coerceIn(40, 220)
    fun setFixedBpm(ctx: Context, value: Int) = p(ctx).edit().putInt(KEY_BPM, value.coerceIn(40, 220)).apply()

    /** Always while worn, or only during a workout NOOP records. */
    fun scope(ctx: Context): String = p(ctx).getString(KEY_SCOPE, ALWAYS).takeIf { it == WORKOUT } ?: ALWAYS
    fun setScope(ctx: Context, value: String) = p(ctx).edit().putString(KEY_SCOPE, value).apply()

    fun reminderMode(ctx: Context): String =
        p(ctx).getString(KEY_REMINDER, STANDARD).takeIf { it == EVERY_TWO_SECONDS } ?: STANDARD
    fun setReminderMode(ctx: Context, value: String) = p(ctx).edit().putString(KEY_REMINDER, value).apply()

    /** The "Buzz at N BPM" line: the whole-bpm value the wearer crosses, from the core. Blocking; call off the main thread. */
    fun buzzAtBpm(ctx: Context, profile: ProfileStore): Int? = CoreAlerts.hrCeiling(
        mode = mode(ctx), allowedZone = allowedZone(ctx), fixedBpm = fixedBpm(ctx),
        zoneLowerBpm = profile.hrZoneSet.zones.map { it.lower }, maxHr = profile.hrMax,
    )?.displayBpm
}

/**
 * Feeds one smoothed live heart rate at a time to the core's ceiling decision and sends the strap the buzz it asks for.
 * The only thing that lives here is the engine's memory between two samples, which the core hands back each time. The
 * buzz send itself is the existing [buzz] (the BLE path is untouched); unverified without a strap.
 */
internal class HrCeilingMonitor(private val appContext: Context) {
    private val lock = Mutex()
    private var state: CoreAlerts.CeilingState? = null

    /** Whether a ceiling episode is running, as of the last sample the core answered. */
    @Volatile var episodeActive: Boolean = false
        private set

    fun onSample(
        scope: CoroutineScope, profile: ProfileStore, bpm: Int?, nowSec: Long, switchOn: Boolean, linked: Boolean,
        workoutRunning: Boolean, confirmRecovery: Boolean, buzz: (Int) -> Unit,
    ) {
        // Everything the core needs is read here, on the caller's thread; the core call and the wait for it are not.
        val mode = HrCeilingPrefs.mode(appContext)
        val zone = HrCeilingPrefs.allowedZone(appContext)
        val fixed = HrCeilingPrefs.fixedBpm(appContext)
        val reminder = HrCeilingPrefs.reminderMode(appContext)
        val inScope = HrCeilingPrefs.scope(appContext) == HrCeilingPrefs.ALWAYS || workoutRunning
        val gate = switchOn && linked && inScope
        val lower = profile.hrZoneSet.zones.map { it.lower }
        val maxHr = profile.hrMax
        scope.launch(Dispatchers.Default) {
            val loops = lock.withLock {
                val answer = CoreAlerts.hrCeiling(mode, zone, fixed, lower, maxHr, nowSec, bpm, gate, reminder, state)
                    ?: return@withLock 0
                state = answer.state
                episodeActive = answer.episodeActive
                // The iPhone always confirms a recovery; "Recovery buzz" is the Android switch that was there before.
                if (answer.cue == "recovered" && !confirmRecovery) 0 else answer.loops
            }
            if (loops > 0) withContext(Dispatchers.Main) { buzz(loops) }
        }
    }
}
