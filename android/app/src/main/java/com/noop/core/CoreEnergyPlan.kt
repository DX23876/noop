package com.noop.core

import android.content.Context
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import org.json.JSONArray
import org.json.JSONObject

/**
 * Fork (DX23876), Android parity plan 2.3: the Energy Plan from the shared core (`CoreEnergyPlan`). The wearer's
 * choices live under the Apple keys (`EnergyPlanStore`); every figure arrives computed. Blocking; call off the
 * main thread.
 */
object CoreEnergyPlan {
    private const val FORMULA_LOG = "energy.bmrFormulaLog"
    private const val MEASURED_BASAL = "energy.measuredBMR"
    private const val SCALE_CORRECTION = "energy.scaleCorrection"
    private const val ACTIVITY = "energy.activityLevel"
    private const val TARGET = "energy.targetKgPerWeek"

    data class Formula(val formula: String, val basalKcal: Double?, val available: Boolean)
    data class Plan(
        val available: Boolean, val measuredMeanKcal: Double?, val allDaysMeanKcal: Double?, val measuredDays: Int,
        val totalDays: Int, val burnQuality: String?, val balanceIntakeDays: Int?, val balanceKcal: Double?, val balanceLowKcal: Double?, val balanceHighKcal: Double?,
        val intakeDays: Int, val balanceWindowDays: Int?, val thermicEffectKcal: Double?, val todayIntakeKcal: Double?, val todayProjectedBurnKcal: Double?,
        val todayBalanceKcal: Double?, val todayVerdict: String?, val activity: String, val targetKgPerWeek: Double,
        val dailyDeltaKcal: Double?, val observedKcalPerKg: Double?, val currentFormula: String, val formulaTdeeKcal: Double?,
        val formulas: List<Formula>, val corridorKcal: List<Double>, val corridorSpreadKcal: Double?,
        /** Each day's measured burn in the window, today until now. */
        val burnedByDay: Map<String, Double> = emptyMap(),
        /** The everyday share's mean over the same days, for the plan's burn-model note. */
        val everydayMeanKcal: Double? = null,
        /** The measured resting rate, when entered: value, day and whether it is over a year old. */
        val measuredBasalKcal: Double? = null, val measuredBasalDay: String? = null, val measuredBasalOld: Boolean = false,
    )

    fun formulaLog(context: Context): String = NoopPrefs.of(context).getString(FORMULA_LOG, "") ?: ""
    /** iOS `EnergyPlanStore.measuredRate`: a measured resting rate as the core's `MeasuredRestingRate` JSON. */
    fun measuredBasal(context: Context): String = NoopPrefs.of(context).getString(MEASURED_BASAL, "") ?: ""
    fun setMeasuredBasal(context: Context, json: String?) =
        NoopPrefs.of(context).edit().apply { if (json.isNullOrEmpty()) remove(MEASURED_BASAL) else putString(MEASURED_BASAL, json) }.apply()
    fun activity(context: Context): String = NoopPrefs.of(context).getString(ACTIVITY, "light") ?: "light"
    fun targetKgPerWeek(context: Context): Double = NoopPrefs.of(context).getFloat(TARGET, 0f).toDouble()
    fun setActivity(context: Context, level: String) = NoopPrefs.of(context).edit().putString(ACTIVITY, level).apply()
    fun setTargetKgPerWeek(context: Context, rate: Double) =
        NoopPrefs.of(context).edit().putFloat(TARGET, rate.toFloat()).apply()

    fun plan(context: Context, dismissedWorkouts: List<String>): Plan? {
        if (!SwiftCore.available) return null
        CoreUserInputs.ensure(context)
        val profile = ProfileStore.from(context)
        val args = JSONObject().withGoalProfile(profile).withGoalHostSettings(context).put("sex", profile.sex)
            .put("lastSync", goalLastSync(context)).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
            .put("activity", activity(context)).put("targetKgPerWeek", targetKgPerWeek(context))
        return parse(SwiftCore.call("energy.plan", args.toString()) ?: return null)
    }

    /** Today's intake in kcal; zero records a day of eating nothing. */
    fun recordIntake(kcal: Double): Boolean {
        if (!SwiftCore.available) return false
        val json = SwiftCore.call("energy.recordIntake", JSONObject().put("kcal", kcal).toString()) ?: return false
        val ok = runCatching { JSONObject(json).optBoolean("ok") }.getOrDefault(false)
        if (ok) CoreShadow.noteDataChanged()
        return ok
    }

    /** A measured resting rate for the body on [day] (core `energy.measuredBasal`): its JSON and whether it is within 40 %. */
    fun measuredRate(context: Context, kcalPerDay: Double, day: String): Pair<String, Boolean>? {
        if (!SwiftCore.available) return null
        val profile = ProfileStore.from(context)
        val json = SwiftCore.call("energy.measuredBasal", JSONObject().put("kcalPerDay", kcalPerDay).put("day", day)
            .put("weightKg", profile.weightKg).put("heightCm", profile.heightCm).put("age", profile.age)
            .put("sex", profile.sex).toString()) ?: return null
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        val rate = o.optString("rate").ifEmpty { return null }
        return rate to (o.optString("plausible") == "true")
    }

    /** iOS `EnergyPlanStore.scaleCorrection`: the scale's correction of the strap's burn, as the core's JSON. */
    fun scaleCorrection(context: Context): String = NoopPrefs.of(context).getString(SCALE_CORRECTION, "") ?: ""

    /** What the energy page shows about the scale (core `ScaleCorrectionUpdate.Snapshot`). */
    data class Scale(
        val status: String, val factor: Double, val targetFactor: Double?, val sinceDay: String?, val scaleKcal: Double?,
        val strapKcal: Double?, val completeDays: Int, val weeks: Int, val weighIns: Int, val spanDays: Int,
        val tooUncertain: Boolean, val holding: Boolean, val appliesToBasal: Boolean,
        /** The early look's scale over strap, a direction only (`ScaleBurn.Gates.early`). */
        val earlyRatio: Double? = null,
    )

    /**
     * The scale read again (core `energy.scale`, `ScaleCorrectionUpdate.run`): the evaluated state is stored, and a
     * first proposal posts one quiet row to the inbox (decision Q33: no notification).
     */
    fun scale(context: Context, dismissedWorkouts: List<String>): Scale? {
        if (!SwiftCore.available) return null
        val profile = ProfileStore.from(context)
        val args = JSONObject().withGoalProfile(profile).withGoalHostSettings(context).put("sex", profile.sex)
            .put("lastSync", goalLastSync(context)).put("dismissedWorkouts", JSONArray(dismissedWorkouts))
            .put("plan", NoopPrefs.of(context).getString(CoreDietPlan.KEY, "") ?: "")
        val o = runCatching { JSONObject(SwiftCore.call("energy.scale", args.toString()) ?: return null) }.getOrNull() ?: return null
        val before = runCatching { JSONObject(scaleCorrection(context)).optString("status") }.getOrDefault("")
        val state = o.optString("state")
        if (state.isNotEmpty()) NoopPrefs.of(context).edit().putString(SCALE_CORRECTION, state).apply()
        val s = o.optJSONObject("snapshot") ?: return null
        fun dbl(k: String): Double? = if (s.has(k) && !s.isNull(k)) s.getDouble(k) else null
        val scale = Scale(s.optString("status"), s.optDouble("factor", 1.0), dbl("targetFactor"),
                          s.optString("sinceDay").ifEmpty { null }, dbl("scaleKcal"), dbl("strapKcal"), s.optInt("completeDays"),
                          s.optInt("weeks"), s.optInt("weighIns"), s.optInt("spanDays"), s.optBoolean("tooUncertain"),
                          s.optBoolean("holding"), s.optBoolean("appliesToBasal", true), dbl("earlyRatio"))
        if (scale.status == "proposed" && before != "proposed") {
            com.noop.ui.UpdateStore.from(context).post(com.noop.ui.UpdateItem(
                kind = com.noop.ui.UpdateKind.READING,
                title = context.getString(com.noop.R.string.energy_scale_bell_title),
                message = context.getString(com.noop.R.string.energy_scale_bell_text), deepLink = "energy"))
        }
        return scale
    }

    /** The wearer's answer to the scale: accept, decline, off or on (core `energy.scaleAction`). */
    fun scaleAction(context: Context, action: String): Boolean {
        if (!SwiftCore.available) return false
        val json = SwiftCore.call("energy.scaleAction",
            JSONObject().put("state", scaleCorrection(context)).put("action", action).toString()) ?: return false
        val state = runCatching { JSONObject(json).getString("state") }.getOrNull() ?: return false
        NoopPrefs.of(context).edit().putString(SCALE_CORRECTION, state).apply()
        CoreShadow.noteDataChanged()
        return true
    }

    /** Appends a basal-formula switch effective from today, as Apple's append-only log does. */
    fun switchFormula(context: Context, formula: String): Boolean {
        if (!SwiftCore.available) return false
        val json = SwiftCore.call("energy.switchFormula",
            JSONObject().put("log", formulaLog(context)).put("formula", formula).toString()) ?: return false
        val log = runCatching { JSONObject(json).getString("log") }.getOrNull() ?: return false
        NoopPrefs.of(context).edit().putString(FORMULA_LOG, log).apply()
        CoreShadow.noteDataChanged()
        return true
    }

    internal fun parse(json: String): Plan? {
        val o = runCatching { JSONObject(json) }.getOrNull() ?: return null
        if (o.has("error")) return null
        fun dbl(k: String): Double? = if (o.has(k) && !o.isNull(k)) o.getDouble(k) else null
        fun str(k: String): String? = if (o.has(k) && !o.isNull(k)) o.getString(k) else null
        val formulas = o.optJSONArray("formulas")
        val corridor = o.optJSONArray("corridorKcal")
        return Plan(
            available = o.optBoolean("available"), measuredMeanKcal = dbl("measuredMeanKcal"), allDaysMeanKcal = dbl("allDaysMeanKcal"),
            measuredDays = o.optInt("measuredDays"), totalDays = o.optInt("totalDays"), burnQuality = str("burnQuality"),
            balanceIntakeDays = if (o.has("balanceIntakeDays")) o.getInt("balanceIntakeDays") else null, balanceKcal = dbl("balanceKcal"),
            balanceLowKcal = dbl("balanceLowKcal"), balanceHighKcal = dbl("balanceHighKcal"), intakeDays = o.optInt("intakeDays"),
            balanceWindowDays = if (o.has("balanceWindowDays")) o.getInt("balanceWindowDays") else null,
            thermicEffectKcal = dbl("thermicEffectKcal"), todayIntakeKcal = dbl("todayIntakeKcal"),
            todayProjectedBurnKcal = dbl("todayProjectedBurnKcal"), todayBalanceKcal = dbl("todayBalanceKcal"),
            todayVerdict = str("todayVerdict"), activity = o.optString("activity", "light"),
            targetKgPerWeek = o.optDouble("targetKgPerWeek", 0.0), dailyDeltaKcal = dbl("dailyDeltaKcal"),
            observedKcalPerKg = dbl("observedKcalPerKg"), currentFormula = o.optString("currentFormula"),
            formulaTdeeKcal = dbl("formulaTdeeKcal"),
            formulas = if (formulas == null) emptyList() else (0 until formulas.length()).map {
                formulas.getJSONObject(it).let { f ->
                    Formula(f.getString("formula"), if (f.isNull("basalKcal")) null else f.optDouble("basalKcal"), f.optBoolean("available"))
                }
            },
            corridorKcal = if (corridor == null) emptyList() else (0 until corridor.length()).map { corridor.getDouble(it) },
            corridorSpreadKcal = dbl("corridorSpreadKcal"),
            burnedByDay = o.optJSONObject("burnedByDay")?.let { m -> m.keys().asSequence().associateWith { m.getDouble(it) } } ?: emptyMap(),
            everydayMeanKcal = dbl("everydayMeanKcal"),
            measuredBasalKcal = dbl("measuredBasalKcal"), measuredBasalDay = str("measuredBasalDay"),
            measuredBasalOld = o.optBoolean("measuredBasalOld"),
        )
    }
}
