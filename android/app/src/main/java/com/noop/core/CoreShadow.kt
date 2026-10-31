package com.noop.core

import android.content.Context
import android.util.Log
import com.noop.analytics.Baselines
import com.noop.ui.NoopPrefs
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Fork (DX23876), Android plan D-5: the shared core running beside the Kotlin pipeline. The Bluetooth client hands
 * every frame it receives here as well, and the core's Collector and Backfiller bank them in the core's own store
 * (`files/core/noop-core.sqlite`). Nothing goes back to the strap from here: the Kotlin client keeps the link and
 * acks history itself. Every call is a no-op when the core is not in this build.
 *
 * The point is evidence before the switch: after each offload the client logs what the core banked beside what
 * the Kotlin pipeline banked, so a tester's strap log shows whether the two agree.
 */
object CoreShadow {
    private const val TAG = "CoreShadow"
    private const val PREFS = "forge"
    private const val KEY_CONFIRMS_ACK = "coreConfirmsHistoryAck"
    @Volatile private var started = false
    private val revision = MutableStateFlow(0L)
    val dataRevision = revision.asStateFlow()
    fun noteDataChanged() { revision.update { it + 1 } }

    /**
     * Opens the core's store and starts the session once per process; after that, re-points the running session
     * at [deviceId] when the strap changed inside the process ([followActive] false keeps the session's strap: a
     * screen's id can lag the Bluetooth client's), and hands the core every registered WHOOP. Blocks on the
     * registry read; call off the main thread.
     */
    fun ensureStarted(context: Context, deviceId: String, followActive: Boolean = true) {
        if (!SwiftCore.available) return
        if (!started) synchronized(this) {
            if (started) return@synchronized
            if (!installResources(context)) return
            val store = File(context.filesDir, "core/noop-core.sqlite").apply { parentFile?.mkdirs() }
            val result = SwiftCore.shadowStart(store.path, deviceId)
            started = result == 0
            Log.i(TAG, "shadow session start=$result for $deviceId")
        }
        if (started) followDevices(context, deviceId.takeIf { followActive })
    }

    /**
     * The active strap and every registered WHOOP for the core's union reads (`ShadowSession.setDevices`): the
     * same set the Room fallback reads (`WhoopRepository.rawWhoopSourceIds`), archived straps included, so a
     * retired strap's nights and workouts stay on the screens with the Lab switch on. A changed [activeId] also
     * re-points the core's writers, in order with the frames already queued; null keeps the session's strap.
     * Blocks on the registry read.
     */
    fun followDevices(context: Context, activeId: String?) {
        if (!started) return
        val app = context.applicationContext as? com.noop.NoopApplication
        // An unreadable registry keeps the list the core already has (null) instead of narrowing it.
        val registered = app?.let { a ->
            runCatching {
                kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) { a.deviceRegistry.all() }
            }.onFailure { Log.w(TAG, "registry unreadable; the core keeps its registered straps: ${it.message}") }
                .getOrNull()
        }?.let(::registeredWhoopIds)
        SwiftCore.call("shadow.devices", devicesArgs(activeId.orEmpty(), registered))
    }

    /**
     * Re-points the running session at [activeId] without reading the registry, so frames the client sends after
     * a strap switch reach the core under the new id. Cheap; safe on the Bluetooth thread.
     */
    fun followActive(activeId: String) {
        if (started) SwiftCore.call("shadow.devices", devicesArgs(activeId, null))
    }

    /** The registry's WHOOP ids in registry order, as Room's `rawWhoopSourceIds` filters them. */
    internal fun registeredWhoopIds(rows: List<com.noop.data.PairedDeviceRow>): List<String> =
        rows.filter { it.brand.equals("WHOOP", ignoreCase = true) }.map { it.id }

    internal fun devicesArgs(activeId: String, registered: List<String>?): String =
        org.json.JSONObject().put("active", activeId)
            .apply { if (registered != null) put("registered", org.json.JSONArray(registered)) }.toString()

    /**
     * The core's protocol schema and exercise catalogue, shipped as APK assets because Android has
     * no SwiftPM resource bundle, copied into the files directory when their bytes change and announced to the core
     * before anything reads them.
     */
    private fun installResources(context: Context): Boolean {
        val dir = File(context.filesDir, "core-resources").apply { mkdirs() }
        for (name in RESOURCES) {
            val target = File(dir, name)
            val installed = runCatching {
                val bytes = context.assets.open(name).use { it.readBytes() }
                // Length alone cannot detect an updated schema whose replacement happens to be the same size.
                if (!target.isFile || !target.readBytes().contentEquals(bytes)) target.writeBytes(bytes)
            }.onFailure { Log.e(TAG, "resource $name not unpacked; core session not started: ${it.message}") }
            if (installed.isFailure) return false
        }
        val args = org.json.JSONObject().put("dir", dir.path)
            .put("home", File(context.filesDir, "core-home").apply { mkdirs() }.path)
        localizationFile(context, dir)?.let { args.put("l10n", it.path) }
        val result = SwiftCore.call("core.setResources", args.toString())
        val ready = runCatching { org.json.JSONObject(result.orEmpty()).optBoolean("ok") }.getOrDefault(false)
        if (!ready) Log.e(TAG, "protocol schema not installed; core session not started: $result")
        return ready
    }

    private val RESOURCES = listOf("whoop_protocol.json", "exercise-catalog.json")

    /**
     * The wearer's language for the text the shared core writes (`CoreLocalization`): the app's chosen language, or
     * the phone's, as the per-language table `core-l10n/<code>.l10n` built from the Apple String Catalog. English,
     * or a language without a table, leaves the core on its English source.
     */
    private fun localizationFile(context: Context, dir: File): File? {
        val tag = com.noop.ui.AppLanguagePrefs.selected(context).storageValue ?: java.util.Locale.getDefault().language
        val code = tag.substringBefore('-').lowercase()
        if (code == "en") return null
        val target = File(dir, "l10n.json")
        return runCatching {
            val bytes = context.assets.open("core-l10n/$code.l10n").use { it.readBytes() }
            if (!target.isFile || !target.readBytes().contentEquals(bytes)) target.writeBytes(bytes)
            target
        }.getOrNull()
    }

    /** Re-reads the language after the wearer picked another one in Settings, without restarting the core. */
    fun applyLanguage(context: Context) {
        if (!SwiftCore.available) return
        val dir = File(context.filesDir, "core-resources").apply { mkdirs() }
        val args = org.json.JSONObject()
        localizationFile(context, dir)?.let { args.put("l10n", it.path) }
        SwiftCore.call("core.setLanguage", args.toString())
        noteDataChanged()
    }

    fun family(whoop5: Boolean) { if (started) SwiftCore.shadowFamily(whoop5) }

    fun clock(device: Long, wall: Long) { if (started) SwiftCore.shadowClock(device, wall) }

    fun liveFrame(frame: ByteArray) { if (started) SwiftCore.shadowLiveFrame(frame) }

    fun offloadBegin(continuedAfterRows: Boolean) { if (started) SwiftCore.shadowOffloadBegin(continuedAfterRows) }

    fun offloadFrame(frame: ByteArray) { if (started) SwiftCore.shadowOffloadFrame(frame) }

    fun flush() { if (started) SwiftCore.shadowFlush() }

    /** Starts a new tally in order with the frames, as the Kotlin client resets its own counters per link. */
    fun resetTally() { if (started) SwiftCore.shadowResetTally() }

    /**
     * Runs the core's daily pass on its own store after the frames queued so far, with the wearer's analysis choices
     * as the Apple app passes its own (`AppAnalysisHost`): the Effort model, the sleep stager, the wake check, the
     * nightly HRV window, the day start and the two Lab passes ([CoreFeatures]). Until 2026-10-26 the core
     * hard-wired Banister Effort and the V1 stager here, so an untouched install scored differently from an
     * untouched iPhone.
     */
    fun analyze(age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int,
                effortBanister: Boolean, sleepStagerV2: Boolean, motionAwareWake: Boolean, deepHrvWindow: Boolean,
                dayCycleMode: String, healthspan: Boolean, rhythmAge: Boolean, extras: String) {
        if (started) {
            SwiftCore.shadowAnalyze(age, sex, weightKg, heightCm, hrMaxOverride, effortBanister,
                                    sleepStagerV2, motionAwareWake, deepHrvWindow, dayCycleMode,
                                    healthspan, rhythmAge, extras)
            noteDataChanged()
        }
    }

    /** Publish a new read revision only after the queued analysis has committed its rows. Blocking IO call. */
    fun awaitQueuedAnalysis(): Boolean {
        check(android.os.Looper.myLooper() != android.os.Looper.getMainLooper())
        val completed = started && SwiftCore.shadowAwaitQueuedEvents()
        if (completed) noteDataChanged()
        return completed
    }

    /**
     * The further choices the core's pass reads (`CoreAnalysis.applyExtras`): the deleted nights and detected
     * workouts as "start:end" tokens, the waist, the step estimate's calibration, baseline anchors, the Lab's
     * SpO₂ estimate and strength share of Effort, and the Energy Plan's basal formula. [historyRescore] makes that
     * one pass cover the whole history with unchanged days reused, for a switch that moves only some old days.
     */
    fun extras(context: Context, profile: com.noop.ui.ProfileStore, dismissedSleep: List<Pair<Long, Long>>,
               dismissedWorkouts: List<Pair<Long, Long>>, spo2CandidateDisplay: Boolean,
               historyRescore: Boolean = false): String =
        org.json.JSONObject().apply {
            put("sleepStagerMethod", com.noop.ble.PuffinExperiment.from(context).sleepStagerMethod)
            put("spo2CandidateDisplay", spo2CandidateDisplay)
            put("effortStrengthBonus", CoreFeatures.effortStrengthBonus(context))
            put("historyRescore", historyRescore)
            put("hrvBaselineEpoch", NoopPrefs.of(context).getLong(Baselines.hrvBaselineEpochKey, 0L).toDouble())
            put("recoveryBaselineEpoch", NoopPrefs.of(context).getLong(Baselines.recoveryBaselineEpochKey, 0L).toDouble())
            put("dismissedSleep", org.json.JSONArray(dismissedSleep.map { "${it.first}:${it.second}" }))
            put("dismissedWorkouts", org.json.JSONArray(dismissedWorkouts.map { "${it.first}:${it.second}" }))
            put("waistCm", profile.waistCm)
            put("formulaLog", CoreEnergyPlan.formulaLog(context))
            put("stepTicksPerStep", profile.stepTicksPerStep)
            put("stepsManualCoefficient", profile.stepsManualCoefficient)
            put("stepsCalibrationCoefficient", profile.stepsCalibrationCoefficient)
            put("stepsCalibrationSampleDays", profile.stepsCalibrationSampleDays)
            put("stepsCalibrationConfidence", profile.stepsCalibrationConfidence)
            put("stepsCalibrationManual", profile.stepsCalibrationManual)
            put("stepsHasBankedMotion", profile.stepsHasBankedMotion)
        }.toString()

    /** Today's scores from the core's last pass, as one line; null before one finished. */
    fun today(): String? = if (started) SwiftCore.shadowToday() else null

    /**
     * Android plan E-4, behind a switch that is off by default: whether the history ack waits for the core. On, the
     * client sends a chunk's ack only once the core has persisted that chunk (the safe-trim rule, now for the
     * core's store); a chunk the core has not banked in time keeps its ack, so the strap keeps it and sends it
     * again on the next sync.
     */
    fun confirmsHistoryAck(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY_CONFIRMS_ACK, false)

    fun setConfirmsHistoryAck(context: Context, on: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY_CONFIRMS_ACK, on).apply()
    }

    /** True once the core has banked the chunk ending in [endData]; false when it has not within [timeoutMs]. */
    fun awaitBanked(endData: ByteArray, timeoutMs: Long): Boolean =
        started && SwiftCore.shadowAwaitBanked(endData, timeoutMs)

    /**
     * Whether to send a history chunk's ack now. With the switch off the client acks as before. With it on the ack
     * waits for the core and is held when the core is not running or has not banked the chunk, so a chunk is only
     * ever trimmed on the strap once both stores have it.
     */
    fun mayAck(confirms: Boolean, coreRunning: Boolean, banked: () -> Boolean): Boolean =
        !confirms || (coreRunning && banked())

    val running: Boolean get() = started

    /** What the core banked from history this process, per stream; null when no session runs. */
    fun tally(): String? = if (started) SwiftCore.shadowTally() else null
}
