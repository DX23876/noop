package com.noop.core

import android.content.Context
import com.noop.ble.PuffinExperiment
import com.noop.data.WhoopRepository
import com.noop.ui.HrvWindow
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import org.json.JSONObject

/**
 * Fork (DX23876), Settings parity package 5 (CAL-05 to CAL-07): Settings › Calculations › "If scores look wrong" reads
 * what the shared engine is doing (`analysis.maintenance`) and asks it for the two repair actions
 * (`analysis.refreshToday`, `analysis.reanalyzeRecent`), the Swift `CoreAnalysisMaintenance`. Both actions are
 * diagnostics: they never move the analysis recipe. They return at once; the page polls [status].
 */
object CoreAnalysisMaintenance {
    /** What the engine is doing: [working] names the [task] ("background", "recent" or "today"). */
    data class Status(
        val working: Boolean,
        val task: String?,
        /** Unix seconds of the last repair that finished, or null before one did. */
        val lastRunSeconds: Long?,
        /** Why the last repair did not finish: "noCurrentDayActivity" or "unfinished", else null. */
        val failure: String?,
        val progress: Progress?,
    ) {
        /** Set only while a pass is in flight (`AnalysisProgress`). */
        data class Progress(
            val stage: String,
            val fraction: Double,
            val day: Int,
            val totalDays: Int,
            val unchanged: Int,
            val eta: Coarse?,
            val gap: Coarse,
            val stalled: Boolean,
        )

        /** A duration as the core rounds it: [unit] is "s" or "min". */
        data class Coarse(val value: Int, val unit: String)
    }

    /** The engine's state now; null when this build has no core or no session runs. */
    fun status(context: Context): Status? = runCatching {
        if (!CoreShadow.openStore(context)) return@runCatching null
        parseStatus(JSONObject(SwiftCore.call("analysis.maintenance", "{}") ?: return@runCatching null))
    }.getOrNull()

    /** Raises today's Effort from the raw heart rate without a full pass. False when one is already running. */
    fun refreshToday(context: Context, repo: WhoopRepository, deviceId: String): Boolean = start(context, repo, deviceId, "analysis.refreshToday")

    /**
     * Scores the last 21 days again with the wearer's current choices. Only derived scores change: raw data and the
     * wearer's own sleep and workout corrections stay. False when a pass is already running.
     */
    fun reanalyzeRecent(context: Context, repo: WhoopRepository, deviceId: String): Boolean = start(context, repo, deviceId, "analysis.reanalyzeRecent")

    /**
     * Scores the recent days again after the wearer re-anchored the Charge baseline (the daily pass with the current
     * choices; it is not a repair and does not appear as one on the page). Blocks until the pass stored its rows,
     * so call it off the main thread.
     */
    fun rescore(context: Context, repo: WhoopRepository, deviceId: String) {
        runCatching {
            if (!CoreShadow.openStore(context)) return
            CoreShadow.ensureStarted(context, deviceId)
            val r = Request.read(context, repo, deviceId)
            CoreShadow.analyze(r.age, r.sex, r.weightKg, r.heightCm, r.hrMaxOverride, r.effortBanister, r.sleepStagerV2,
                               r.motionAwareWake, r.deepHrvWindow, r.dayCycleMode, r.healthspan, r.rhythmAge, r.extras)
            CoreShadow.awaitQueuedAnalysis()
        }
    }

    private fun start(context: Context, repo: WhoopRepository, deviceId: String, op: String): Boolean = runCatching {
        if (!CoreShadow.openStore(context)) return@runCatching false
        CoreShadow.ensureStarted(context, deviceId)
        val answer = JSONObject(SwiftCore.call(op, Request.read(context, repo, deviceId).toJson().toString())
                                    ?: return@runCatching false)
        answer.optBoolean("started")
    }.getOrDefault(false)

    /** The profile and choices the daily pass takes (`CoreShadow.analyze`), read the way the sync's own pass reads them. */
    private class Request(
        val age: Int, val sex: String, val weightKg: Double, val heightCm: Double, val hrMaxOverride: Int,
        val effortBanister: Boolean, val sleepStagerV2: Boolean, val motionAwareWake: Boolean,
        val deepHrvWindow: Boolean, val dayCycleMode: String, val healthspan: Boolean, val rhythmAge: Boolean,
        val extras: String,
    ) {
        fun toJson(): JSONObject = JSONObject()
            .put("age", age).put("sex", sex).put("weightKg", weightKg).put("heightCm", heightCm)
            .put("hrMaxOverride", hrMaxOverride).put("effortBanister", effortBanister)
            .put("sleepStagerV2", sleepStagerV2).put("motionAwareWake", motionAwareWake)
            .put("deepHrvWindow", deepHrvWindow).put("dayCycleMode", dayCycleMode)
            .put("healthspan", healthspan).put("rhythmAge", rhythmAge).put("extras", extras)

        companion object {
            fun read(context: Context, repo: WhoopRepository, deviceId: String): Request {
                val store = ProfileStore.from(context)
                val profile = store.toUserProfile()
                val experiment = PuffinExperiment.from(context)
                val extras = kotlinx.coroutines.runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                    CoreShadow.extras(
                        context, store,
                        dismissedSleep = repo.dismissedSleeps(deviceId).map { it.startTs to it.endTs },
                        dismissedWorkouts = repo.dismissedDetectedUnion(deviceId).map { it.startTs to it.endTs },
                        spo2CandidateDisplay = NoopPrefs.spo2CandidateDisplay(context))
                }
                return Request(
                    age = profile.age.toInt(), sex = profile.sex, weightKg = profile.weightKg,
                    heightCm = profile.heightCm, hrMaxOverride = store.hrMaxOverride,
                    effortBanister = NoopPrefs.banisterEffort(context),
                    sleepStagerV2 = experiment.experimentalSleepV2, motionAwareWake = experiment.motionAwareWake,
                    deepHrvWindow = UnitPrefs.hrvWindow(context) == HrvWindow.DEEP_SLEEP,
                    dayCycleMode = NoopPrefs.dayCycleMode(context).persistedValue,
                    healthspan = CoreFeatures.healthspan(context), rhythmAge = CoreFeatures.rhythmAge(context),
                    extras = extras)
            }
        }
    }

    internal fun parseStatus(o: JSONObject): Status {
        fun coarse(j: JSONObject?) = j?.let { Status.Coarse(it.optInt("value"), it.optString("unit", "s")) }
        val progress = o.optJSONObject("progress")?.let { p ->
            Status.Progress(
                stage = p.optString("stage"), fraction = p.optDouble("fraction"), day = p.optInt("day"),
                totalDays = p.optInt("totalDays"), unchanged = p.optInt("unchanged"),
                eta = coarse(p.optJSONObject("eta")), gap = coarse(p.optJSONObject("gap")) ?: Status.Coarse(5, "s"),
                stalled = p.optBoolean("stalled"))
        }
        return Status(
            working = o.optString("phase") == "working",
            task = o.optString("task").takeIf { it.isNotEmpty() },
            lastRunSeconds = if (o.has("lastRun")) o.optDouble("lastRun").toLong() else null,
            failure = o.optString("failure").takeIf { it.isNotEmpty() },
            progress = progress)
    }
}
