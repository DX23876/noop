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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
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
    val l = s.labels

    // Quick presets (`presetBar`): one tap sets style, voice, emoji, proactive messages and reply length.
    if (s.presets.isNotEmpty()) NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(l["presets"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
            Text(l["presetsDetail"].orEmpty(), style = NoopType.footnote, color = Palette.textSecondary)
            s.presets.forEach { p ->
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { set("preset", p.id) }
                        .padding(vertical = 4.dp)) {
                    Text(p.label, style = NoopType.subhead, color = Palette.textPrimary)
                    Text(p.detail, style = NoopType.footnote, color = Palette.textSecondary)
                }
            }
        }
    }
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

/** "Show Coach on Today" and its avatar switch (`coachVisibilityBar`); shown while the coach is switched on. */
@Composable
internal fun CoachTodayCard(vm: CoachViewModel) {
    val settings by vm.coachSettings.collectAsStateWithLifecycle()
    val s = settings ?: return
    val context = androidx.compose.ui.platform.LocalContext.current
    if (!BottomBarStyleStore.coachEnabled) return
    var shown by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(CoachTodayPrefs.shown(context)) }
    var avatar by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(CoachTodayPrefs.avatar(context)) }
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ToggleRow(s.labels["today"].orEmpty(), s.labels["todayDetail"], shown) { shown = it; CoachTodayPrefs.setShown(context, it) }
            if (shown) ToggleRow(s.labels["todayAvatar"].orEmpty(), s.labels["todayAvatarDetail"], avatar) {
                avatar = it; CoachTodayPrefs.setAvatar(context, it)
            }
        }
    }
}

/** "Enable AI Coach" (`coachFeatureBar`): off hides the coach and its check-ins; chats and data stay saved. */
@Composable
internal fun CoachFeatureCard(vm: CoachViewModel) {
    val settings by vm.coachSettings.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.loadCoachSettings() }
    val s = settings ?: return
    val context = androidx.compose.ui.platform.LocalContext.current
    val on = BottomBarStyleStore.coachEnabled
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        ToggleRow(s.labels["feature"].orEmpty(), s.labels[if (on) "featureOn" else "featureOff"], on) {
            vm.setCoachFeature(context, it)
        }
    }
}

/**
 * The background models per role (`backgroundModelsSection`): chat summaries, card analyses and the closer look,
 * each empty to fall back as on iOS. A model name is saved when the field loses focus or Done is pressed.
 */
@Composable
internal fun CoachBackgroundModelsCard(vm: CoachViewModel) {
    val settings by vm.coachSettings.collectAsStateWithLifecycle()
    val s = settings ?: return
    val l = s.labels
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(l["models"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
                Text(l["modelsDetail"].orEmpty(), style = NoopType.footnote, color = Palette.textSecondary)
            }
            RoleModelField(l["summary"], l["summaryDetail"], s.memoryModel, null) {
                vm.updateCoachSettings(JSONObject().put("memoryModel", it))
            }
            RoleModelField(l["card"], l["cardDetail"], s.cardModel, null) {
                vm.updateCoachSettings(JSONObject().put("cardModel", it))
            }
            RoleModelField(l["deep"], l["deepDetail"], s.deepModel, l["deepOff"]) {
                vm.updateCoachSettings(JSONObject().put("deepModel", it))
            }
        }
    }
}

@Composable
private fun RoleModelField(title: String?, caption: String?, value: String, emptyLabel: String?, onSave: (String) -> Unit) {
    var draft by androidx.compose.runtime.saveable.rememberSaveable(value) { androidx.compose.runtime.mutableStateOf(value) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title.orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
        Text(caption.orEmpty(), style = NoopType.footnote, color = Palette.textSecondary)
        androidx.compose.material3.OutlinedTextField(
            value = draft, onValueChange = { draft = it }, singleLine = true, colors = noopFieldColors(),
            placeholder = emptyLabel?.let { { Text(it, color = Palette.textTertiary) } },
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Done),
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { if (draft != value) onSave(draft.trim()) }),
            modifier = Modifier.fillMaxWidth().onFocusChanged { if (!it.isFocused && draft != value) onSave(draft.trim()) },
        )
    }
}

/** What the questions cost (`tokenUsageBar`, `cumulativeUsageBar`), shown once a question was counted. */
@Composable
internal fun CoachUsageCard(vm: CoachViewModel) {
    val settings by vm.coachSettings.collectAsStateWithLifecycle()
    val s = settings ?: return
    if (s.usage.isEmpty()) return
    NoopCard(padding = 14.dp, tint = Palette.chargeColor) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(s.labels["usage"].orEmpty(), style = NoopType.subhead, color = Palette.textPrimary)
            s.usage.forEach { u ->
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(u.title, style = NoopType.caption, color = Palette.textTertiary)
                    Text(u.line, style = NoopType.footnote, color = Palette.textSecondary)
                    u.detail?.let { Text(it, style = NoopType.footnote, color = Palette.textTertiary) }
                }
            }
            Text(s.labels["usageNote"].orEmpty(), style = NoopType.caption, color = Palette.textSecondary)
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
