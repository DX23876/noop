package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.core.CoreCoach
import org.json.JSONObject

/**
 * The coaching and data-access cards of the iOS coach settings (`CoachSettingsView`'s Coaching and Privacy & data
 * pages): coaching style, reply length, proactive messages, emoji, summarising past chats, the privacy level and
 * each data-access purpose. Every value lives in the shared coach; every label comes from the iOS catalogue.
 */
@Composable
internal fun CoachSharedSettingsCards(vm: CoachViewModel) {
    val settings by vm.coachSettings.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadCoachSettings() }
    val s = settings ?: return
    fun set(key: String, value: Any) = vm.updateCoachSettings(JSONObject().put(key, value))

    ChoiceCard(uiString(R.string.coach_settings_style), s.personas, s.persona) { set("persona", it) }
    ChoiceCard(uiString(R.string.coach_settings_length), s.verbosities, s.verbosity) { set("verbosity", it) }
    ChoiceCard(uiString(R.string.coach_settings_proactive), s.proactives, s.proactive) { set("proactive", it) }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ToggleRow(uiString(R.string.coach_settings_emoji), null, s.emoji) { set("emoji", it) }
            ToggleRow(uiString(R.string.coach_settings_summarise), s.autoSummarizeDetail, s.autoSummarize) {
                set("autoSummarize", it)
            }
        }
    }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Overline(uiString(R.string.coach_settings_privacy_level))
            Segmented(s.accessModes, s.accessMode) { set("accessMode", it) }
            s.purposes.forEach { p ->
                ToggleRow(p.label, p.detail, p.on) { vm.updateCoachSettings(JSONObject().put("purpose", p.id).put("on", it)) }
            }
        }
    }
}

/** A segmented choice with the selected option's one-line explanation under it. */
@Composable
private fun ChoiceCard(title: String, choices: List<CoreCoach.Choice>, selected: String, onPick: (String) -> Unit) {
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Overline(title)
            Segmented(choices, selected, onPick)
            choices.firstOrNull { it.id == selected }?.detail?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = NoopType.footnote, color = Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun Segmented(choices: List<CoreCoach.Choice>, selected: String, onPick: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.surfaceInset).padding(3.dp)) {
        choices.forEach { c ->
            val on = c.id == selected
            Box(
                Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                    .background(if (on) Palette.surfaceRaised else Color.Transparent)
                    .clickable { onPick(c.id) }
                    .padding(vertical = 8.dp, horizontal = 4.dp)
                    .semantics { this.selected = on },
                contentAlignment = Alignment.Center,
            ) {
                Text(c.label, style = NoopType.subhead, textAlign = TextAlign.Center, maxLines = 2,
                     color = if (on) Palette.textPrimary else Palette.textSecondary)
            }
        }
    }
}

@Composable
private fun ToggleRow(title: String, detail: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = NoopType.subhead, color = Palette.textPrimary)
            if (!detail.isNullOrEmpty()) Text(detail, style = NoopType.footnote, color = Palette.textSecondary)
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
