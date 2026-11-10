package com.noop.ui.forge

import android.text.format.DateFormat
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Error
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.MonitorHeart
import androidx.compose.material.icons.rounded.ShowChart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.R
import com.noop.analytics.VitalBands
import com.noop.ui.AppViewModel
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileAvatar
import com.noop.ui.Sparkline
import com.noop.ui.UnitPrefs
import com.noop.ui.Vital
import com.noop.ui.latestVitals
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Fork (DX23876), Forge parity 2026-11: the Health tab of the new iOS design (`ForgeHealthView`). Last night's
 * vitals against the wearer's own range first, then heart and stress, body and energy, and the long-term views
 * (Trends moved here from its own tab, as on iOS).
 *
 * The vitals come from [latestVitals], the same resolver the Health monitor draws its tiles from and the Kotlin
 * twin of iOS's `BodyVitalSigns.readings`, so the two screens always agree on what is in range.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ForgeHealthTab(padding: PaddingValues, width: ForgeWidth, viewModel: AppViewModel) {
    val context = LocalContext.current
    val colors = Forge.colors
    val days by viewModel.recentDays.collectAsStateWithLifecycle()
    val spo2CandidateByDay by viewModel.spo2CandidateByDay.collectAsStateWithLifecycle()
    val hrvOverCountByDay by viewModel.hrvOverCountByDay.collectAsStateWithLifecycle()
    var settingsOpen by remember { mutableStateOf(false) }
    // Read again when Settings closes, so a unit or SpO₂ choice made there shows without a restart.
    val tempUnit = remember(settingsOpen) { UnitPrefs.temperature(context) }
    val spo2Toggle = remember(settingsOpen) { NoopPrefs.spo2CandidateDisplay(context) }
    val vitals = remember(days, spo2CandidateByDay, hrvOverCountByDay, tempUnit, spo2Toggle) {
        latestVitals(days, tempUnit, spo2CandidateByDay, spo2Toggle, hrvOverCountByDay = hrvOverCountByDay)
            // The raw optical reading is an experimental instrument; an empty one is noise on this tab.
            .filter { !(it.key == "spo2raw" && it.value == null) }
            .sortedBy { listOf("hrv", "rhr", "spo2", "resp", "skin", "spo2raw").indexOf(it.key).let { i -> if (i < 0) 99 else i } }
    }
    val scored = vitals.filter { it.banding.band != VitalBands.Band.NO_DATA && it.key != "spo2raw" }
    val inRange = scored.count { it.banding.band == VitalBands.Band.IN_RANGE }

    val more = rememberMoreNavigator()
    var trendsOpen by remember { mutableStateOf(false) }
    fun open(dest: MoreDest) = more.push(MoreRoute.Dest(dest))

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(padding)
            .padding(horizontal = ForgeMetrics.screenPadding),
        verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3),
    ) {
        val openMore = LocalForgeOpenMore.current
        TabHeader(stringResource(R.string.nav_health), onProfile = { openMore?.invoke() ?: run { settingsOpen = true } })

        // The tab's answer: how many of last night's vitals sat in the wearer's own range, then each by name.
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.forge_health_vitals_last_night), style = Forge.type.subhead,
                 color = Forge.sceneInk.secondary)
            Text(if (scored.isEmpty()) stringResource(R.string.forge_health_no_readings)
                 else stringResource(R.string.forge_health_in_range, inRange, scored.size),
                 style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                scored.forEach { v -> RangeChip(v) }
            }
        }
        // The first vital outside the range, told in a card of its own under the chips, as iOS's `offRangeCard`.
        scored.firstOrNull { it.banding.band == VitalBands.Band.OUT_OF_RANGE }?.let { OffRangeCard(it) }

        Heading(stringResource(R.string.forge_health_vitals))
        vitals.chunked(if (width == ForgeWidth.Compact) 2 else 3).forEach { row ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                row.forEach { v -> VitalTile(v, Modifier.weight(1f)) { open(MoreDest.Health) } }
                repeat((if (width == ForgeWidth.Compact) 2 else 3) - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }

        Heading(stringResource(R.string.forge_health_heart_stress))
        DestCard(listOf(MoreDest.Stress, MoreDest.Ecg, MoreDest.BeatRhythm, MoreDest.Live)) { open(it) }

        Heading(stringResource(R.string.forge_health_body_energy))
        DestCard(listOf(MoreDest.Body, MoreDest.Energy, MoreDest.Biomarkers)) { open(it) }

        Heading(stringResource(R.string.forge_health_long_term))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            HubRow(Icons.Rounded.ShowChart, colors.charge, stringResource(R.string.nav_trends), "") { trendsOpen = true }
            HubDivider()
            HubRow(Icons.Rounded.GridView, colors.accent, stringResource(R.string.forge_health_all_metrics), "") {
                open(MoreDest.Explore)
            }
        }
        val longTerm = listOf(MoreDest.AgeLess, MoreDest.RhythmAge, MoreDest.Insights).filter { it.shown(context) }
        if (longTerm.isNotEmpty()) DestCard(longTerm) { open(it) }
        Spacer(Modifier.height(ForgeMetrics.space4))
    }

    MoreOverlay(more, viewModel, onOpenSettings = { settingsOpen = true })
    if (trendsOpen) {
        ForgeOverlayPage(onDismiss = { trendsOpen = false }) { ForgeTrendsScreen(PaddingValues(), width, viewModel) }
    }
    if (settingsOpen) {
        ForgeOverlayPage(onDismiss = { settingsOpen = false }) { ForgeSettings(viewModel, onClose = { settingsOpen = false }) }
    }
}

/** A tab's own header row, as iOS's `ForgeLargeHeader`: the title with today's date, the profile at the end. */
@Composable
internal fun TabHeader(title: String, onProfile: () -> Unit) {
    val locale = Locale.getDefault()
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space4), verticalAlignment = Alignment.CenterVertically) {
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(title) }
                withStyle(Forge.type.subhead.toSpanStyle().copy(color = Forge.sceneInk.secondary)) {
                    append("  ")
                    append(LocalDate.now().format(DateTimeFormatter.ofPattern(
                        DateFormat.getBestDateTimePattern(locale, "EEEMMMd"), locale)))
                }
            },
            style = Forge.type.title2, color = Forge.sceneInk.text, maxLines = 1, modifier = Modifier.weight(1f),
        )
        ProfileAvatar(size = 36.dp, contentDescription = stringResource(R.string.forge_qa_profile_settings),
                      modifier = Modifier.clickable(role = Role.Button, onClick = onProfile))
    }
}

/** A section's title above its card, as iOS's `ForgeSectionHeading`: bold, sentence case. */
@Composable
private fun Heading(text: String) {
    Text(text, style = Forge.type.headline.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text,
         modifier = Modifier.padding(top = ForgeMetrics.space3))
}

@Composable
private fun RangeChip(v: Vital) {
    val colors = Forge.colors
    val ok = v.banding.band == VitalBands.Band.IN_RANGE
    Row(
        Modifier.heightIn(min = 30.dp)
            .background(if (ok) colors.surface.copy(alpha = 0.75f) else colors.effort.copy(alpha = 0.16f), CircleShape)
            .padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (ok) Icons.Rounded.CheckCircle else Icons.Rounded.Error, contentDescription = null,
             tint = if (ok) colors.charge else colors.effort, modifier = Modifier.size(16.dp))
        Spacer(Modifier.size(6.dp))
        Text(v.label, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
             color = if (ok) colors.text else colors.effort)
    }
}

/** A vital outside the wearer's range: which, last night's figure with the yardstick's word, and its course. */
@Composable
private fun OffRangeCard(v: Vital) {
    val colors = Forge.colors
    val state = stringResource(if (v.banding.basis == VitalBands.Basis.PERSONAL) R.string.forge_h_off_baseline
                               else R.string.forge_h_off_typical)
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 16.dp) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.MonitorHeart, contentDescription = null, tint = colors.accent, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(6.dp))
            Text(stringResource(R.string.forge_h_off_label), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.accent)
        }
        Spacer(Modifier.height(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_h_off_title, v.label), style = Forge.type.title2.copy(fontWeight = FontWeight.Bold),
             color = colors.text)
        v.value?.let { value ->
            val figure = v.format(value)
            val sentence = stringResource(R.string.forge_h_off_last_night, figure, v.unit, state)
            // The figure and its unit bold, wherever the language puts them in the sentence.
            val bold = "$figure ${v.unit}".trim()
            val at = sentence.indexOf(bold)
            Spacer(Modifier.height(ForgeMetrics.space1))
            Text(buildAnnotatedString {
                append(sentence)
                if (at >= 0) addStyle(SpanStyle(fontWeight = FontWeight.Bold, color = colors.text), at, at + bold.length)
            }, style = Forge.type.body, color = colors.textSecondary)
        }
        if (v.sparkline.size > 1) {
            Spacer(Modifier.height(ForgeMetrics.space3))
            Sparkline(v.sparkline, color = colors.effort)
        }
    }
}

/** One vital: its name, the figure large with the unit small beside it, and its recent course. */
@Composable
private fun VitalTile(v: Vital, modifier: Modifier, onClick: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(modifier.clickable(role = Role.Button, onClick = onClick), contentPadding = 14.dp) {
        Text(v.label, style = Forge.type.subhead, color = colors.textSecondary, maxLines = 1)
        Spacer(Modifier.height(ForgeMetrics.space1))
        Text(
            buildAnnotatedString {
                append(v.value?.let(v.format) ?: "–")
                if (v.value != null && v.unit.isNotEmpty()) {
                    withStyle(Forge.type.footnote.toSpanStyle().copy(color = colors.textSecondary)) { append(" " + v.unit) }
                }
            },
            style = Forge.type.heroNumber, color = colors.text, maxLines = 1,
        )
        Spacer(Modifier.height(ForgeMetrics.space2))
        if (v.sparkline.size > 1) Sparkline(v.sparkline, color = v.metricColor)
    }
}
