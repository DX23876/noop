package com.noop.ui.forge

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R

// Settings subpages, wave 2: NOOP limitations (iOS `NoopLimitationsView`, Forge body) in the Forge look: what NOOP reads
// off a WHOOP 4.0 against a 5.0/MG. The marks are the classic screen's and mirror the decoders and analytics (full = read
// live, partial = an on-device estimate or an experimental or firmware-gated read, none = not from the strap); nothing is
// computed here.

private enum class Support { FULL, PARTIAL, NONE }

private data class Row(val feature: Int, val whoop4: Support, val whoop5: Support)

private val ROWS = listOf(
    Row(R.string.forge_w_live_heart, Support.FULL, Support.FULL),
    Row(R.string.fsw2_lim_hrv, Support.FULL, Support.FULL),
    Row(R.string.fsw2_lim_sleep, Support.FULL, Support.FULL),
    Row(R.string.fsw2_lim_recovery, Support.FULL, Support.FULL),
    // Partial on both generations: the shown respiratory rate is an on-device estimate off the R-R stream, with no
    // family branch (#1331 blanks it on an over-counted R-R night).
    Row(R.string.today_driver_respiratory, Support.PARTIAL, Support.PARTIAL),
    Row(R.string.fsw2_lim_stress, Support.FULL, Support.FULL),
    Row(R.string.fsw2_lim_workouts, Support.FULL, Support.FULL),
    Row(R.string.l10n_settings_screen_skin_temperature_fc103030, Support.PARTIAL, Support.FULL),
    Row(R.string.l10n_today_screen_steps_cdde4f20, Support.PARTIAL, Support.FULL),
    Row(R.string.fsw2_lim_spo2, Support.NONE, Support.NONE),
    Row(R.string.forge_tl_ecg, Support.NONE, Support.PARTIAL),
    Row(R.string.forge_log_blood_pressure, Support.NONE, Support.NONE),
)

@Composable
internal fun LimitationsSettingsPage(title: String, onBack: () -> Unit) {
    val colors = Forge.colors
    SettingsColumn {
        PageTitle(title, onBack)
        Text(stringResource(R.string.fsw2_lim_blurb), style = Forge.type.subhead, color = Forge.sceneInk.secondary,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        SettingsCard(title = stringResource(R.string.fsw2_lim_title), blurb = null) {
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.l10n_whoop_model_comparison_screen_feature_ad565d9d), style = Forge.type.caption,
                         color = colors.textTertiary, modifier = Modifier.weight(1f))
                    Text("4.0", style = Forge.type.caption, color = colors.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(52.dp))
                    Text(stringResource(R.string.fsw2_lim_col_mg), style = Forge.type.caption, color = colors.textTertiary, textAlign = TextAlign.Center, modifier = Modifier.width(52.dp))
                }
                ROWS.forEachIndexed { index, row ->
                    if (index > 0) RowDivider()
                    val feature = stringResource(row.feature)
                    val said = stringResource(R.string.fsw2_lim_a11y, feature, row.whoop4.spoken(), row.whoop5.spoken())
                    Row(Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = said },
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(feature, style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                        Cell(row.whoop4)
                        Cell(row.whoop5)
                    }
                }
            }
        }
        SettingsCard(title = stringResource(R.string.fsw2_lim_legend), blurb = null) {
            Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                LegendRow(Support.FULL, stringResource(R.string.fsw2_lim_legend_full))
                LegendRow(Support.PARTIAL, stringResource(R.string.fsw2_lim_legend_partial))
                LegendRow(Support.NONE, stringResource(R.string.fsw2_lim_legend_none))
            }
        }
    }
}

@Composable
private fun LegendRow(state: Support, label: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Cell(state)
        Text(label, style = Forge.type.footnote, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun Cell(state: Support) {
    val (icon: ImageVector, tint: Color) = when (state) {
        Support.FULL -> Icons.Rounded.Check to ForgeTokens.StrandPalette.statusPositive.resolve()
        Support.PARTIAL -> Icons.Rounded.Remove to ForgeTokens.StrandPalette.statusWarning.resolve()
        // iOS draws "not from the strap" in the quiet tertiary grey, not an alarm red.
        Support.NONE -> Icons.Rounded.Close to Forge.colors.textTertiary
    }
    Box(Modifier.width(52.dp), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun Support.spoken(): String = stringResource(when (this) {
    Support.FULL -> R.string.fsw2_lim_yes
    Support.PARTIAL -> R.string.fsw2_lim_partly
    Support.NONE -> R.string.fsw2_lim_no
})
