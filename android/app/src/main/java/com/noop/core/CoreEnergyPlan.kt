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
    )

    fun formulaLog(context: Context): String = NoopPrefs.of(context).getString(FORMULA_LOG, "") ?: ""
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
        )
    }
}
