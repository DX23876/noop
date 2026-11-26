package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreProfile
import com.noop.ui.Palette
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// Settings › Profile › Heart-rate zones: the zone editor (iOS `HRZoneEditorSheet`). The rules (what a legal set is, the
// notch of a step, the seeding of the mode not in use) are the shared core's (`profile.zones`); this draws the page.

/**
 * The zone editor as a Settings page: how the zones are defined (standard, percent of the maximum, or beats), the five
 * starting points as steppers over a preview of the bands, and what the bands do and do not change. Nothing is stored
 * until Save, and Save is off while the draft is not a legal set.
 */
@Composable
internal fun HrZonesSettingsPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val profile = remember { ProfileStore.from(context) }
    val maxHr = remember { profile.hrMax }
    val autoSource = remember { if (profile.hrMaxOverride > 0) "manual" else profile.hrMaxAutoSource.ifEmpty { "gellish" } }
    var mode by remember { mutableStateOf(profile.hrZoneMode) }
    var percents by remember { mutableStateOf(profile.hrZonePercents) }
    var bpms by remember { mutableStateOf(profile.hrZoneBpms) }
    var draft by remember { mutableStateOf<CoreProfile.ZoneDraft?>(null) }
    // The steps tapped and not yet applied, oldest first. The core moves the bound and answers with the new draft; a tap
    // that lands while an answer is on its way restarts the effect, which then applies every step still waiting.
    var pending by remember { mutableStateOf<List<Pair<Int, Boolean>>>(emptyList()) }
    var revision by remember { mutableStateOf(0) }

    LaunchedEffect(mode, revision) {
        val steps = pending
        val answer = withContext(Dispatchers.IO) {
            var last = CoreProfile.zones(mode, percents, bpms, maxHr, autoSource)
            for (step in steps) {
                val now = last ?: break
                last = CoreProfile.zones(mode, now.percents, now.bpms, maxHr, autoSource, step)
            }
            last
        }
        if (answer != null) {
            draft = answer
            percents = answer.percents
            bpms = answer.bpms
            pending = pending.drop(steps.size)
        }
    }
    BackHandler(onBack = onBack)

    SettingsColumn {
        PageTitle(stringResource(R.string.fsp1_hz_title), onBack)
        Text(stringResource(R.string.fsp1_hz_max, maxHr), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        SettingsCard(stringResource(R.string.fsp1_hz_what), null) {
            Text(stringResource(R.string.fsp1_hz_what_body), style = Forge.type.subhead, color = Forge.colors.textSecondary)
            Text(stringResource(R.string.fsp1_hz_what_note), style = Forge.type.footnote, color = Forge.colors.textTertiary)
        }
        SettingsCard(null, null) {
            Text(stringResource(R.string.fsp1_hz_mode), style = Forge.type.body, color = Forge.colors.text)
            Segmented(listOf("auto", "percent", "bpm"), mode, { m ->
                stringResource(when (m) { "percent" -> R.string.fsp1_hz_percent; "bpm" -> R.string.fsp1_hz_beats; else -> R.string.fsp1_hz_standard })
            }) { mode = it }
            Text(stringResource(when (mode) {
                "percent" -> R.string.fsp1_hz_blurb_percent
                "bpm" -> R.string.fsp1_hz_blurb_bpm
                else -> R.string.fsp1_hz_blurb_auto
            }), style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
        SettingsCard(null, null) {
            val shown = draft
            shown?.bands?.forEachIndexed { index, band ->
                if (index > 0) RowDivider()
                ZoneRow(band, mode, percents.getOrNull(index), bpms.getOrNull(index)) { up ->
                    pending = pending + (index to up)
                    revision++
                }
            }
            if (shown != null && !shown.legal) {
                RowDivider()
                Text(stringResource(if (mode == "bpm") R.string.fsp1_hz_invalid_bpm else R.string.fsp1_hz_invalid_percent, maxHr),
                     style = Forge.type.footnote, color = ForgeTokens.Color.systemOrange.resolve())
            }
        }
        SettingsCard(stringResource(R.string.fsp1_hz_changes), null) {
            Text(stringResource(R.string.fsp1_hz_changes_body), style = Forge.type.subhead, color = Forge.colors.textSecondary)
            Text(stringResource(R.string.fsp1_hz_changes_note), style = Forge.type.footnote, color = Forge.colors.textTertiary)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3),
            verticalAlignment = Alignment.CenterVertically) {
            if (mode != "auto") {
                OutlinedButton(onClick = { mode = "auto" }) {
                    Text(stringResource(R.string.fsp1_hz_use_standard), style = Forge.type.footnote, color = Forge.colors.text)
                }
            }
            Spacer(Modifier.weight(1f))
            Button(enabled = draft?.legal == true, colors = ButtonDefaults.buttonColors(containerColor = Forge.colors.accent,
                       contentColor = Forge.colors.onAccent),
                   onClick = {
                       profile.setHrZoneConfig(mode, percents, bpms)
                       onBack()
                   }) { Text(stringResource(R.string.fsp1_hz_save), style = Forge.type.footnote) }
        }
    }
}

/** One band: its colour, the zone and the other unit's reading, the figure in this mode's unit, and the stepper. */
@Composable
private fun ZoneRow(band: CoreProfile.ZoneBand, mode: String, percent: Double?, bpm: Double?, onStep: (Boolean) -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Box(Modifier.width(6.dp).height(34.dp).background(Palette.hrZoneColor(band.number), RoundedCornerShape(3.dp)))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(stringResource(R.string.fsp1_hz_zone, band.number), style = Forge.type.subhead, color = colors.text)
            // Both readings are always on screen: the other unit's span under the one being edited.
            Text(if (mode == "bpm") stringResource(R.string.fsp1_hz_percent_range, band.lowerPercentText, band.upperPercentText)
                 else stringResource(R.string.fsp1_hz_bpm_range, band.lowerBpm, band.upperBpm),
                 style = Forge.type.caption, color = colors.textSecondary)
        }
        val figure = when (mode) {
            "percent" -> percent?.let { trimmed(it) } ?: "—"
            "bpm" -> bpm?.let { Math.round(it).toString() } ?: "—"
            else -> band.lowerPercentText
        }
        Text(figure, style = Forge.type.bodyNumber, color = if (mode == "auto") colors.textTertiary else colors.text)
        Text(stringResource(if (mode == "bpm") R.string.fsp1_hz_bpm_unit else R.string.fsp1_hz_percent_unit),
             style = Forge.type.caption, color = colors.textTertiary)
        if (mode != "auto") Stepper("", onMinus = { onStep(false) }, onPlus = { onStep(true) })
    }
}

/** A percent as the shortest exact text: "65", or "62.5" when a half was set. */
private fun trimmed(value: Double): String =
    if (Math.abs(value - Math.rint(value)) < 1e-9) Math.rint(value).toLong().toString() else "%.1f".format(java.util.Locale.ROOT, value)
