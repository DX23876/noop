package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.Functions
import androidx.compose.material.icons.rounded.Thermostat
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.analytics.ChargeDriver
import com.noop.analytics.ChargeDriverLabel
import com.noop.analytics.ChargeDriverUnit
import com.noop.analytics.ChargeDriverVerdict
import com.noop.analytics.RecoveryDrivers
import com.noop.analytics.ScoreConfidence
import com.noop.ui.AppViewModel
import com.noop.ui.chargeConfidenceTier
import com.noop.ui.recoveryChargeDrivers
import java.util.Locale
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android parity: "What shaped your Charge" as iOS shows it from Today and Momentum
 * (`LiquidTodayView.chargeBreakdownSheet`, `ChargeBreakdownSection`, `ChargeDriverRow`, `SkinTempDeviationRow`): each
 * term the recovery score used with its signed points, value against baseline, a 16-pip bar scaled to the day's
 * biggest mover and the verdict, the confidence tag, and the night's skin temperature against the wearer's normal.
 * The rows come from the same drivers and baselines the Charge ring is scored with (`recoveryChargeDrivers`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ChargeBreakdownSheet(viewModel: AppViewModel, onHowCalculated: (() -> Unit)?, onDismiss: () -> Unit) {
    val baselines by viewModel.chargeBaselines.collectAsState()
    val today by viewModel.today.collectAsState()
    val days by viewModel.recentDays.collectAsState()
    // The row the ring reads: today's once scored, else the last scored night carried over (#543).
    val row = today?.takeIf { it.recovery != null } ?: days.lastOrNull { it.recovery != null && it.day <= (today?.day ?: "9999-12-31") }
    val drivers = remember(baselines, row) { recoveryChargeDrivers(baselines, row) }
    val tier = remember(baselines, row) { chargeConfidenceTier(baselines, row) }
    val skin = row?.skinTempDevC
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                     containerColor = Forge.colors.canvas) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
            Box(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_cb_title), style = Forge.type.headline, color = Forge.colors.text,
                     textAlign = TextAlign.Center, modifier = Modifier.align(Alignment.Center))
                Text(stringResource(R.string.forge_cb_done), style = Forge.type.body, color = Forge.colors.accent,
                     modifier = Modifier.align(Alignment.CenterEnd).clickable(onClick = onDismiss).padding(8.dp))
            }
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                if (drivers.isEmpty()) {
                    Text(stringResource(R.string.forge_cb_none), style = Forge.type.headline, color = Forge.colors.text)
                } else Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    HorizontalDivider(color = Forge.colors.divider)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.forge_cb_section).uppercase(), style = Forge.type.overline,
                             color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
                        ConfidenceTierChip(tier)
                    }
                    val maxMagnitude = drivers.maxOf { abs(it.deltaPoints) }.coerceAtLeast(1)
                    drivers.forEach { ChargeDriverRow(it, maxMagnitude) }
                    if (skin != null) SkinTempDeviationRow(skin)
                }
            }
            if (onHowCalculated != null) {
                Row(Modifier.fillMaxWidth().background(Forge.colors.inset, RoundedCornerShape(ForgeMetrics.groupedRadius))
                        .clickable(onClick = onHowCalculated).padding(ForgeMetrics.space4),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    Icon(Icons.Rounded.Functions, contentDescription = null, tint = Forge.colors.charge, modifier = Modifier.size(16.dp))
                    Column(Modifier.weight(1f)) {
                        Text(stringResource(R.string.forge_cb_how), style = Forge.type.subhead, color = Forge.colors.text)
                        Text(stringResource(R.string.forge_cb_how_sub), style = Forge.type.caption, color = Forge.colors.textTertiary)
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary)
                }
            }
        }
    }
}

/** The sheet with its "How Charge is calculated" page, which opens over it as iOS's navigation link does. */
@Composable
internal fun ChargeBreakdownHost(viewModel: AppViewModel, onDismiss: () -> Unit) {
    var guide by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    if (guide) {
        ForgeOverlayPage(onDismiss = { guide = false }) {
            ForgeSceneBackdrop(ForgeBackdrop.Canvas) {
                androidx.activity.compose.BackHandler { guide = false }
                Hosted(stringResource(R.string.forge_cb_how), onBack = { guide = false }) {
                    com.noop.ui.ScoringGuideScreen(onClose = { guide = false })
                }
            }
        }
    } else ChargeBreakdownSheet(viewModel, onHowCalculated = { guide = true }, onDismiss = onDismiss)
}

/** The dot and tag of the score's confidence: REL. when solid, EST. while building, CALIBRATING before. */
@Composable
private fun ConfidenceTierChip(tier: ScoreConfidence) {
    val (tag, color) = when (tier) {
        ScoreConfidence.SOLID -> R.string.forge_cb_rel to ForgeTokens.StrandPalette.statusPositive.resolve()
        ScoreConfidence.BUILDING -> R.string.forge_cb_est to ForgeTokens.StrandPalette.statusWarning.resolve()
        ScoreConfidence.CALIBRATING -> R.string.forge_cb_cal to Forge.colors.textTertiary
    }
    Row(Modifier.background(color.copy(alpha = 0.14f), RoundedCornerShape(50)).border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(50))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(7.dp).background(color, CircleShape))
        Text(stringResource(tag), style = Forge.type.overline, color = color)
    }
}

@Composable
private fun chipLabel(points: Int): String = when {
    points == 1 -> stringResource(R.string.forge_cb_pt_plus, points)
    points == -1 -> stringResource(R.string.forge_cb_pt, points)
    points > 0 -> pluralStringResource(R.plurals.forge_cb_pts_plus, points, points)
    points < 0 -> pluralStringResource(R.plurals.forge_cb_pts, abs(points), points)
    else -> stringResource(R.string.forge_cb_zero)
}

/** Green from the top of the recovery ramp for a supporting term, red from its foot for a limiting one. */
@Composable
private fun chipColor(points: Int): Color = when {
    points > 0 -> ForgeTokens.StrandPalette.recovery100.resolve()
    points < 0 -> ForgeTokens.StrandPalette.recovery000.resolve()
    else -> Forge.colors.textTertiary
}

@Composable
private fun ChargeDriverRow(driver: ChargeDriver, maxMagnitude: Int) {
    val hue = chipColor(driver.deltaPoints)
    val label = driverLabel(driver.label)
    val value = driverValue(driver)
    val baseline = driverBaseline(driver)
    val verdict = driverVerdict(driver.verdict)
    val chip = chipLabel(driver.deltaPoints)
    Column(Modifier.semantics { contentDescription = listOf(label, chip, value, baseline, verdict).filter { it.isNotEmpty() }.joinToString(". ") },
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
            Text(chip, style = Forge.type.caption.copy(fontFeatureSettings = "tnum"), color = hue,
                 modifier = Modifier.background(hue.copy(alpha = 0.14f), RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 2.dp))
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(value, style = Forge.type.caption.copy(fontFeatureSettings = "tnum"), color = Forge.colors.textSecondary)
            if (baseline.isNotEmpty()) {
                Text("·", style = Forge.type.caption, color = Forge.colors.textTertiary)
                Text(baseline, style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
        PipBar(abs(driver.deltaPoints).toDouble() / maxMagnitude, hue)
        Text(verdict, style = Forge.type.footnote, color = Forge.colors.textTertiary)
    }
}

/** iOS `PipBar` with 16 segments: the share filled in the hue, the next pip half-lit, the rest on the inset. */
@Composable
private fun PipBar(fraction: Double, tint: Color, segments: Int = 16) {
    val exact = (fraction.coerceIn(0.0, 1.0) * segments)
    val full = exact.toInt()
    Row(Modifier.fillMaxWidth().height(6.dp), horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        repeat(segments) { i ->
            val color = when {
                i < full -> tint
                i == full && exact - full > 0.05 -> tint.copy(alpha = 0.55f)
                else -> Forge.colors.inset
            }
            Box(Modifier.weight(1f).height(6.dp).background(color, RoundedCornerShape(3.dp)))
        }
    }
}

@Composable
private fun SkinTempDeviationRow(deviationC: Double) {
    val amber = ForgeTokens.StrandPalette.metricAmber.resolve()
    val band = RecoveryDrivers.SKIN_TEMP_TYPICAL_BAND_C
    val word = stringResource(when {
        deviationC > band -> R.string.forge_cb_warmer
        deviationC < -band -> R.string.forge_cb_cooler
        else -> R.string.forge_cb_typical
    })
    val text = stringResource(R.string.forge_cb_vs_normal, if (deviationC >= 0) "+" else "", String.format(Locale.getDefault(), "%.1f", deviationC))
    Row(Modifier.padding(top = ForgeMetrics.space1), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Rounded.Thermostat, contentDescription = null, tint = amber, modifier = Modifier.size(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.forge_cb_skin), style = Forge.type.subhead, color = Forge.colors.text)
                Text(text, style = Forge.type.caption.copy(fontFeatureSettings = "tnum", fontWeight = FontWeight.Medium), color = amber)
            }
            Text(word, style = Forge.type.footnote, color = Forge.colors.textTertiary)
        }
        ConfidenceTierChip(ScoreConfidence.SOLID)
    }
}

@Composable
private fun driverLabel(label: ChargeDriverLabel): String = stringResource(when (label) {
    ChargeDriverLabel.HEART_RATE_VARIABILITY -> R.string.today_driver_hrv
    ChargeDriverLabel.RESTING_HEART_RATE -> R.string.today_driver_resting_hr
    ChargeDriverLabel.SLEEP_QUALITY -> R.string.today_driver_sleep_quality
    ChargeDriverLabel.RESPIRATORY_RATE -> R.string.today_driver_respiratory
    ChargeDriverLabel.SKIN_TEMPERATURE -> R.string.today_driver_skin_temperature
})

@Composable
private fun driverValue(d: ChargeDriver): String = when (d.unit) {
    ChargeDriverUnit.MILLISECONDS -> stringResource(R.string.today_driver_value_ms, d.value.roundToInt())
    ChargeDriverUnit.BEATS_PER_MINUTE -> stringResource(R.string.today_driver_value_bpm, d.value.roundToInt())
    ChargeDriverUnit.PERCENT -> stringResource(R.string.today_driver_value_percent, d.value.roundToInt())
    ChargeDriverUnit.BREATHS_PER_MINUTE -> stringResource(R.string.today_driver_value_br_min,
        String.format(Locale.getDefault(), "%.1f", RecoveryDrivers.displayRounded(d.value, 1)))
    ChargeDriverUnit.CELSIUS_DEVIATION -> stringResource(R.string.today_driver_value_temp_deviation,
        String.format(Locale.getDefault(), "%+.1f", d.value))
}

@Composable
private fun driverBaseline(d: ChargeDriver): String {
    val b = d.baseline ?: return ""
    return when (d.unit) {
        ChargeDriverUnit.MILLISECONDS -> stringResource(R.string.today_driver_baseline_ms, b.roundToInt())
        ChargeDriverUnit.BEATS_PER_MINUTE -> stringResource(R.string.today_driver_baseline_bpm, b.roundToInt())
        ChargeDriverUnit.BREATHS_PER_MINUTE -> stringResource(R.string.today_driver_baseline_br_min,
            String.format(Locale.getDefault(), "%.1f", RecoveryDrivers.displayRounded(b, 1)))
        ChargeDriverUnit.PERCENT, ChargeDriverUnit.CELSIUS_DEVIATION -> ""
    }
}

@Composable
private fun driverVerdict(v: ChargeDriverVerdict): String = stringResource(when (v) {
    ChargeDriverVerdict.ABOVE_BASELINE_SUPPORTING -> R.string.today_driver_above_supporting
    ChargeDriverVerdict.BELOW_BASELINE_SUPPORTING -> R.string.today_driver_below_supporting
    ChargeDriverVerdict.ABOVE_BASELINE_LIMITING -> R.string.today_driver_above_limiting
    ChargeDriverVerdict.BELOW_BASELINE_LIMITING -> R.string.today_driver_below_limiting
    ChargeDriverVerdict.SLIGHTLY_ABOVE_BASELINE_SUPPORTING -> R.string.today_driver_slightly_above_supporting
    ChargeDriverVerdict.SLIGHTLY_BELOW_BASELINE_SUPPORTING -> R.string.today_driver_slightly_below_supporting
    ChargeDriverVerdict.SLIGHTLY_ABOVE_BASELINE_LIMITING -> R.string.today_driver_slightly_above_limiting
    ChargeDriverVerdict.SLIGHTLY_BELOW_BASELINE_LIMITING -> R.string.today_driver_slightly_below_limiting
    ChargeDriverVerdict.ABOVE_BASELINE_TOO_SMALL -> R.string.today_driver_above_too_small
    ChargeDriverVerdict.BELOW_BASELINE_TOO_SMALL -> R.string.today_driver_below_too_small
    ChargeDriverVerdict.AT_BASELINE -> R.string.today_driver_at_baseline
    ChargeDriverVerdict.HRV_SATURATION_LIMITING -> R.string.today_driver_hrv_saturation
    ChargeDriverVerdict.STRONG_NIGHT_SUPPORTING -> R.string.today_driver_strong_night
    ChargeDriverVerdict.BELOW_GOOD_NIGHT_LIMITING -> R.string.today_driver_below_good_night
    ChargeDriverVerdict.TYPICAL_NIGHT -> R.string.today_driver_typical_night
    ChargeDriverVerdict.NEAR_BASELINE -> R.string.today_driver_near_baseline
    ChargeDriverVerdict.WARMER_THAN_BASELINE_LIMITING -> R.string.today_driver_warmer_limiting
    ChargeDriverVerdict.COOLER_THAN_BASELINE_LIMITING -> R.string.today_driver_cooler_limiting
})
