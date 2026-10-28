package com.noop.ui.forge

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import com.noop.R
import com.noop.core.CoreEnergyPlan
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android parity plan 2.3: the Energy Plan after `EnergyPlanView`: the band the three routes give
 * (formula, recorded burn, food and scale), today's intake against the day's forecast, the weekly target and what
 * it means per day, how active an ordinary day is, and the basal formula. The shared core computes every figure.
 */
@Composable
internal fun ForgeEnergyPlanPage(onBack: () -> Unit, onDetail: () -> Unit = {}) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var plan by remember { mutableStateOf<CoreEnergyPlan.Plan?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        plan = withContext(Dispatchers.IO) { CoreRead.open(context); CoreEnergyPlan.plan(context, dismissedTrainingWorkouts(context)) }
        loaded = true
    }
    fun change(block: () -> Unit) { scope.launch { withContext(Dispatchers.IO) { block() }; revision++ } }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_energy_title), onBack)
        val p = plan
        if (p == null || !p.available) {
            Text(stringResource(if (loaded) R.string.forge_goals_no_data_yet else R.string.forge_goals_loading),
                 style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        SettingsCard(title = null, blurb = null) {
            LinkRow(stringResource(R.string.forge_ed_title), stringResource(R.string.forge_ed_so_far)) { onDetail() }
        }
        BandCard(p)
        TodayCard(p, onSave = { kcal, done ->
            scope.launch {
                val ok = withContext(Dispatchers.IO) { CoreEnergyPlan.recordIntake(kcal) }
                done(ok); if (ok) revision++
            }
        })
        TargetCard(p) { rate -> change { CoreEnergyPlan.setTargetKgPerWeek(context, rate) } }
        ActivityCard(p) { level -> change { CoreEnergyPlan.setActivity(context, level) } }
        FormulaCard(p) { formula -> change { CoreEnergyPlan.switchFormula(context, formula) } }
    }
}

@Composable
private fun BandCard(p: CoreEnergyPlan.Plan) {
    SettingsCard(title = stringResource(R.string.forge_energy_burn_title), blurb = stringResource(R.string.forge_energy_three_routes)) {
        Route(stringResource(R.string.forge_energy_formula), stringResource(R.string.forge_energy_formula_sub), p.formulaTdeeKcal)
        RowDivider()
        val burnNote = when (p.burnQuality) {
            "measured" -> stringResource(R.string.forge_energy_measured_on, p.measuredDays, p.totalDays)
            "mixed" -> stringResource(R.string.forge_energy_part_measured, p.measuredDays, p.totalDays)
            else -> stringResource(R.string.forge_energy_mostly_modelled, p.measuredDays, p.totalDays)
        }
        Route(stringResource(R.string.forge_energy_band), burnNote, p.measuredMeanKcal ?: p.allDaysMeanKcal)
        RowDivider()
        val balanceNote = if (p.balanceKcal == null || p.balanceIntakeDays == null || p.balanceWindowDays == null)
            stringResource(R.string.forge_energy_needs_logs)
        else stringResource(R.string.forge_energy_logged_of, p.balanceIntakeDays, p.balanceWindowDays)
        Route(stringResource(R.string.forge_energy_food_scale), balanceNote, p.balanceKcal)
        Spacer(Modifier.padding(top = ForgeMetrics.space2))
        Text(p.corridorSpreadKcal?.let { stringResource(R.string.forge_energy_apart, it.roundToInt()) }
                 ?: stringResource(R.string.forge_energy_one_route),
             style = Forge.type.footnote, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun Route(title: String, note: String, kcal: Double?) {
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body, color = Forge.colors.text)
            Text(note, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        Text(kcal?.let { stringResource(R.string.forge_energy_kcal_day, it.roundToInt()) } ?: "–",
             style = Forge.type.subhead, color = Forge.colors.text)
    }
}

@Composable
private fun TodayCard(p: CoreEnergyPlan.Plan, onSave: (Double, (Boolean) -> Unit) -> Unit) {
    var text by remember(p.todayIntakeKcal) { mutableStateOf(p.todayIntakeKcal?.roundToInt()?.toString() ?: "") }
    var saved by remember { mutableStateOf<Boolean?>(null) }
    SettingsCard(title = stringResource(R.string.forge_energy_eaten_today), blurb = null) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = text, onValueChange = { text = it.filter(Char::isDigit).take(5); saved = null },
                              singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                              suffix = { Text("kcal") }, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(ForgeMetrics.space2))
            TextButton(enabled = text.isNotEmpty(), onClick = { onSave(text.toDouble()) { saved = it } }) {
                Text(stringResource(R.string.forge_energy_save))
            }
        }
        saved?.let {
            Text(stringResource(if (it) R.string.forge_energy_saved else R.string.forge_energy_not_saved), style = Forge.type.caption,
                 color = if (it) Forge.colors.textSecondary else ForgeTokens.Color.systemRed.resolve())
        }
        when {
            p.todayProjectedBurnKcal == null -> Text(stringResource(R.string.forge_energy_no_forecast), style = Forge.type.footnote,
                                                     color = Forge.colors.textSecondary)
            p.todayBalanceKcal == null -> Text(stringResource(R.string.forge_energy_add_eaten), style = Forge.type.footnote,
                                               color = Forge.colors.textSecondary)
            else -> {
                val balance = p.todayBalanceKcal
                Text(when (p.todayVerdict) {
                    "maintenance" -> stringResource(R.string.forge_energy_eat_burn)
                    "surplus" -> stringResource(R.string.forge_energy_over, abs(balance).roundToInt())
                    else -> stringResource(R.string.forge_energy_under, abs(balance).roundToInt())
                }, style = Forge.type.body, color = Forge.colors.text)
            }
        }
        p.thermicEffectKcal?.let {
            Text(stringResource(R.string.forge_energy_approx_kcal_day, it.roundToInt()), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }
    }
}

@Composable
private fun TargetCard(p: CoreEnergyPlan.Plan, onRate: (Double) -> Unit) {
    val rate = p.targetKgPerWeek
    val label = when {
        rate == 0.0 -> stringResource(R.string.forge_energy_hold)
        rate < 0 -> stringResource(R.string.forge_energy_lose, kg(-rate))
        else -> stringResource(R.string.forge_energy_gain, kg(rate))
    }
    SettingsCard(title = null, blurb = null) {
        SettingRow(label) {
            Stepper(kg(rate), onMinus = { onRate((rate - 0.25).coerceAtLeast(-1.0)) }, onPlus = { onRate((rate + 0.25).coerceAtMost(0.5)) })
        }
        val delta = p.dailyDeltaKcal
        Text(when {
            rate == 0.0 || delta == null -> stringResource(R.string.forge_energy_eat_burn)
            delta < 0 -> stringResource(R.string.forge_energy_under, abs(delta).roundToInt())
            else -> stringResource(R.string.forge_energy_over, delta.roundToInt())
        }, style = Forge.type.body, color = Forge.colors.text)
        if (rate != 0.0) {
            Text(p.observedKcalPerKg?.let { stringResource(R.string.forge_energy_own_kg, it.roundToInt()) }
                     ?: stringResource(R.string.forge_energy_standard_kg),
                 style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
}

@Composable
private fun ActivityCard(p: CoreEnergyPlan.Plan, onLevel: (String) -> Unit) {
    val levels = listOf("sedentary" to R.string.forge_energy_desk, "light" to R.string.forge_energy_light,
                        "moderate" to R.string.forge_energy_moderate, "high" to R.string.forge_energy_high,
                        "veryHigh" to R.string.forge_energy_very_high)
    SettingsCard(title = stringResource(R.string.forge_energy_how_active), blurb = null) {
        levels.forEachIndexed { i, (level, label) ->
            Choice(stringResource(label), selected = p.activity == level, enabled = true) { onLevel(level) }
            if (i < levels.lastIndex) RowDivider()
        }
    }
}

@Composable
private fun FormulaCard(p: CoreEnergyPlan.Plan, onFormula: (String) -> Unit) {
    SettingsCard(title = stringResource(R.string.forge_energy_basal_formula), blurb = null) {
        p.formulas.forEachIndexed { i, f ->
            val name = when (f.formula) {
                "revisedHarrisBenedict" -> stringResource(R.string.forge_energy_rhb)
                "katchMcArdle" -> stringResource(R.string.forge_energy_katch)
                else -> "Mifflin–St Jeor"
            }
            val detail = if (!f.available) stringResource(R.string.forge_energy_needs_bodyfat)
                         else f.basalKcal?.let { stringResource(R.string.forge_energy_kcal_day, it.roundToInt()) }
            Choice(name, detail, selected = p.currentFormula == f.formula, enabled = f.available) { onFormula(f.formula) }
            if (i < p.formulas.lastIndex) RowDivider()
        }
    }
}

@Composable
private fun Choice(title: String, detail: String? = null, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled && !selected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Forge.type.body, color = if (enabled) Forge.colors.text else Forge.colors.textTertiary)
            detail?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
        }
        if (selected) Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.accent)
    }
}

private fun kg(v: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 2; maximumFractionDigits = 2 }.format(v)
