package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreMetricDetail
import java.util.Locale
import kotlin.math.abs

/** A vital page's key as `MetricCatalog` names the measure (key, source), for the shared insights. */
internal fun vitalCatalogId(key: String): Pair<String, String> = when (key) {
    "resp" -> "resp_rate" to "my-whoop"
    "skin" -> "skin_temp" to "my-whoop"
    "rest" -> "sleep_performance" to "my-whoop"
    "sleep" -> "sleep_total_min" to "my-whoop"
    "steps_est" -> "steps" to "my-whoop"
    "active_kcal" -> "active_kcal" to "apple-health"
    else -> key to "my-whoop"
}

/** Whether a higher reading is the better one, as `MetricCatalog` declares it; null where neither is. */
internal fun vitalHigherIsBetter(key: String): Boolean? = when (key) {
    "hrv", "spo2", "vo2max_est", "recovery", "rest", "vitality", "sleep" -> true
    "rhr", "fitness_age" -> false
    else -> null
}

/** The range's name as the change caption uses it ("vs prev month"), iOS `ExploreRange.name`. */
@Composable
private fun rangeName(range: VitalDetailRange): String = stringResource(when (range) {
    VitalDetailRange.WEEK -> R.string.forge_md_week
    VitalDetailRange.TWO_WEEK -> R.string.forge_md_two_weeks
    VitalDetailRange.THREE_WEEK -> R.string.forge_md_three_weeks
    VitalDetailRange.MONTH -> R.string.forge_md_month
    VitalDetailRange.THREE_MONTH -> R.string.forge_md_quarter
    VitalDetailRange.SIX_MONTH -> R.string.forge_md_six_months
    VitalDetailRange.YEAR -> R.string.forge_md_year
    VitalDetailRange.ALL -> R.string.forge_md_all_time
})

/**
 * The statistics under the chart as iOS `MetricDetailView.statRow` lays them out: the average over the window with its
 * day count and a spark line, then minimum, maximum, the change against the window before and the latest reading.
 */
@Composable
internal fun VitalStatTiles(insights: CoreMetricDetail.Insights, values: List<Double>, range: VitalDetailRange,
                            latest: String, latestCaption: String, accent: androidx.compose.ui.graphics.Color,
                            higherIsBetter: Boolean?, format: (Double) -> String, signed: (Double) -> String) {
    val dash = "—"
    val hasDelta = insights.delta != null
    val deltaColor = when {
        !hasDelta || insights.direction == 0 || higherIsBetter == null -> Palette.textTertiary
        (insights.direction > 0) == higherIsBetter -> Palette.statusPositive
        else -> Palette.statusCritical
    }
    val deltaCaption = when {
        hasDelta -> stringResource(R.string.forge_md_vs_prev, rangeName(range))
        range == VitalDetailRange.ALL -> stringResource(R.string.forge_md_all_history)
        else -> stringResource(R.string.forge_md_no_prior, rangeName(range))
    }
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
        StatTile(stringResource(R.string.forge_md_average), insights.mean?.let(format) ?: dash, Modifier.fillMaxWidth(),
                 caption = pluralStringResource(R.plurals.trends_n_days, insights.n, insights.n), accent = accent,
                 sparkline = values.takeIf { it.size > 1 })
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(stringResource(R.string.forge_md_min), insights.min?.let(format) ?: dash, Modifier.weight(1f))
            StatTile(stringResource(R.string.forge_md_max), insights.max?.let(format) ?: dash, Modifier.weight(1f))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            StatTile(stringResource(R.string.forge_md_change), insights.delta?.let(signed) ?: dash, Modifier.weight(1f),
                     caption = deltaCaption,
                     delta = insights.pctChange?.let { String.format(Locale.getDefault(), "%+.1f%%", it) },
                     deltaColor = deltaColor)
            StatTile(stringResource(R.string.forge_md_latest), latest, Modifier.weight(1f), caption = latestCaption,
                     accent = accent)
        }
    }
}

/** iOS `CoachCardButton`: a small capsule that hands what the page shows to the coach. */
@Composable
internal fun VitalAskCoach(title: String, onAsk: () -> Unit) {
    val label = stringResource(R.string.forge_md_ask_coach)
    val spoken = stringResource(R.string.forge_md_ask_coach_about, title)
    Row(Modifier.background(Palette.surfaceInset, CircleShape).clickable(role = Role.Button, onClick = onAsk)
            .semantics { contentDescription = spoken }.padding(horizontal = 11.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.AutoAwesome, contentDescription = null, tint = Palette.accent, modifier = Modifier.size(14.dp))
        Text(label, style = NoopType.caption, color = Palette.textPrimary)
    }
}

/**
 * iOS `MetricDetailView.correlationCard`: the catalog measures that moved with this one over the window, strongest
 * first, each with its category, the days the two share and the strength as a tube tinted by its sign.
 */
@Composable
internal fun VitalCorrelationsCard(metricTitle: String, rows: List<CoreMetricDetail.Correlation>?) {
    NoopCard {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Overline(stringResource(R.string.forge_md_what_correlates))
                Text(stringResource(R.string.forge_md_correlates_blurb), style = NoopType.footnote, color = Palette.textTertiary)
            }
            when {
                rows == null -> Text(stringResource(R.string.forge_md_scanning), style = NoopType.subhead, color = Palette.accent,
                                     modifier = Modifier.heightIn(min = 56.dp))
                rows.isEmpty() -> Text(stringResource(R.string.forge_md_nothing_correlates, metricTitle.lowercase(Locale.getDefault())),
                                       style = NoopType.subhead, color = Palette.textTertiary, modifier = Modifier.heightIn(min = 56.dp))
                else -> Column {
                    rows.forEachIndexed { i, row ->
                        CorrelationRow(row)
                        if (i < rows.lastIndex) Box(Modifier.fillMaxWidth().height(Metrics.divider).background(Palette.hairline))
                    }
                }
            }
        }
    }
}

@Composable
private fun CorrelationRow(row: CoreMetricDetail.Correlation) {
    val base = if (row.r >= 0) Palette.statusPositive else Palette.statusCritical
    val color = base.copy(alpha = (0.55 + 0.45 * minOf(abs(row.r), 1.0)).toFloat())
    val title = catalogTitle(row.title)
    val strength = (if (row.r >= 0) "+" else "−") + String.format(Locale.getDefault(), "%.2f", abs(row.r))
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp).semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, style = NoopType.body, color = Palette.textPrimary)
            Text(stringResource(R.string.forge_md_days_together, catalogCategory(row.category), row.n),
                 style = NoopType.footnote, color = Palette.textTertiary)
        }
        LiquidTube(frac = minOf(abs(row.r), 1.0), tint = color, height = 8.dp, animated = false, modifier = Modifier.width(64.dp))
        Text(strength, style = NoopType.bodyNumber, color = color, textAlign = TextAlign.End, modifier = Modifier.width(56.dp))
    }
}

/** A catalog measure's name in the reader's language; the core hands the English catalog title. */
@Composable
internal fun catalogTitle(english: String): String = CATALOG_TITLES[english]?.let { stringResource(it) } ?: english

@Composable
private fun catalogCategory(category: String): String = when (category) {
    "Heart" -> stringResource(R.string.forge_mcat_heart)
    "Charge" -> stringResource(R.string.forge_mcat_charge)
    "Rest" -> stringResource(R.string.forge_mcat_rest)
    "Effort" -> stringResource(R.string.forge_mcat_effort)
    "Health" -> stringResource(R.string.forge_mcat_health)
    "Nutrition" -> stringResource(R.string.forge_mcat_nutrition)
    "Mind" -> stringResource(R.string.forge_mcat_mind)
    else -> category
}

/** `MetricCatalog.all`'s titles, by their English catalog key, to the Android strings copied from that catalog. */
private val CATALOG_TITLES: Map<String, Int> = mapOf(
    "Active Energy" to R.string.forge_mc_active_energy,
    "Asleep Time" to R.string.forge_mc_asleep_time,
    "Average Heart Rate" to R.string.forge_mc_average_heart_rate,
    "Basal Energy" to R.string.forge_mc_basal_energy,
    "Blood Oxygen" to R.string.forge_mc_blood_oxygen,
    "Body Age" to R.string.forge_mc_body_age,
    "Body Fat" to R.string.forge_mc_body_fat,
    "Calories" to R.string.forge_mc_calories,
    "Calories In" to R.string.forge_mc_calories_in,
    "Carbs" to R.string.forge_mc_carbs,
    "Charge" to R.string.forge_mc_charge,
    "Day Stress" to R.string.forge_mc_day_stress,
    "Deep (SWS) Sleep" to R.string.forge_mc_deep_sws_sleep,
    "Effort" to R.string.forge_mc_effort,
    "Fat" to R.string.forge_mc_fat,
    "Fitness Age" to R.string.forge_mc_fitness_age,
    "HR Zones (All)" to R.string.forge_mc_hr_zones_all,
    "HR Zones 1-3" to R.string.forge_mc_hr_zones_1_3,
    "HR Zones 4-5" to R.string.forge_mc_hr_zones_4_5,
    "Heart Rate Variability" to R.string.forge_mc_heart_rate_variability,
    "Hours vs Needed" to R.string.forge_mc_hours_vs_needed,
    "Intensity Minutes" to R.string.forge_mc_intensity_minutes,
    "Lean Body Mass" to R.string.forge_mc_lean_body_mass,
    "Light Sleep" to R.string.forge_mc_light_sleep,
    "Max Heart Rate" to R.string.forge_mc_max_heart_rate,
    "Mood" to R.string.forge_mc_mood,
    "Protein" to R.string.forge_mc_protein,
    "REM Sleep" to R.string.forge_mc_rem_sleep,
    "Respiratory Rate" to R.string.forge_mc_respiratory_rate,
    "Rest" to R.string.forge_mc_rest,
    "Resting Heart Rate" to R.string.forge_mc_resting_heart_rate,
    "Restorative Sleep" to R.string.forge_mc_restorative_sleep,
    "Skin Temperature" to R.string.forge_mc_skin_temperature,
    "Sleep Consistency" to R.string.forge_mc_sleep_consistency,
    "Sleep Debt" to R.string.forge_mc_sleep_debt,
    "Sleep Efficiency" to R.string.forge_mc_sleep_efficiency,
    "Sleep Need" to R.string.forge_mc_sleep_need,
    "Sleep Score" to R.string.forge_mc_sleep_score,
    "Steps" to R.string.forge_mc_steps,
    "Steps (estimated)" to R.string.forge_mc_steps_estimated,
    "Strength Activity Time" to R.string.forge_mc_strength_activity_time,
    "Stress" to R.string.forge_mc_stress,
    "Time in Bed" to R.string.forge_mc_time_in_bed,
    "VO₂ Max" to R.string.forge_mc_vo2_max,
    "VO₂ Max (estimated)" to R.string.forge_mc_vo2_max_estimated,
    "Vitality" to R.string.forge_mc_vitality,
    "Weight" to R.string.forge_mc_weight,
)
