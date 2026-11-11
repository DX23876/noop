package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.material.icons.rounded.Psychology
import androidx.compose.material.icons.rounded.Accessibility
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreRead
import com.noop.data.DailyMetric
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.TextStyle
import java.util.Locale

/*
 * Fork (DX23876), Forge parity 2026-11: the Health tab's Focus areas and "Your week in rings" in the new design,
 * rebuilt from iOS's `ForgeHealthView`. iOS opens a focus page of its own per area; Android lists that area's existing
 * pages on one page (Sleep opens the Sleep tab), so every page the Heart and Body groups held stays one tap further.
 */

/** The six focus areas, as iOS's `ForgeFocusArea`, each with the Android pages that belong to it. */
internal enum class FocusArea(val titleRes: Int, val subRes: Int, val icon: ImageVector, val dests: List<MoreDest>) {
    Fitness(R.string.forge_hf_fitness, R.string.forge_hf_fitness_sub, Icons.Rounded.DirectionsRun,
            listOf(MoreDest.Cardio, MoreDest.Strength, MoreDest.TrainingLoad, MoreDest.Workouts)),
    Sleep(R.string.forge_hf_sleep, R.string.forge_hf_sleep_sub, Icons.Rounded.Bedtime, emptyList()),
    Vitals(R.string.forge_hf_vitals, R.string.forge_hf_vitals_sub, Icons.Rounded.Favorite,
           listOf(MoreDest.Health, MoreDest.Ecg, MoreDest.BeatRhythm, MoreDest.Live)),
    Body(R.string.forge_hf_body, R.string.forge_hf_body_sub, Icons.Rounded.Accessibility,
         listOf(MoreDest.Body, MoreDest.Food, MoreDest.Energy, MoreDest.Biomarkers)),
    Mind(R.string.forge_hf_mind, R.string.forge_hf_mind_sub, Icons.Rounded.Psychology,
         listOf(MoreDest.Stress, MoreDest.Breathe, MoreDest.Insights, MoreDest.Journal)),
    More(R.string.forge_hf_more, R.string.forge_hf_more_sub, Icons.Rounded.GridView,
         listOf(MoreDest.Explore, MoreDest.Compare)),
    ;

    @Composable
    fun tint(): Color = when (this) {
        Fitness -> Forge.colors.effort
        Sleep -> Forge.colors.rest
        Vitals -> Forge.colors.heart
        Body -> Forge.colors.charge
        Mind -> ForgeTokens.Color.systemTeal.resolve()
        More -> Forge.colors.accent
    }
}

/** The focus areas as six tiles in two columns, as iOS's grid of `ForgeFocusTile`. */
@Composable
internal fun HealthFocusGrid(onOpen: (FocusArea) -> Unit) {
    val colors = Forge.colors
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        FocusArea.entries.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                pair.forEach { area ->
                    val tint = area.tint()
                    ForgeCard(Modifier.weight(1f).heightIn(min = 112.dp).clickable(role = Role.Button) { onOpen(area) }) {
                        Box(Modifier.size(36.dp).background(tint.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
                            Icon(area.icon, contentDescription = null, tint = tint, modifier = Modifier.size(19.dp))
                        }
                        Spacer(Modifier.height(ForgeMetrics.space3))
                        Text(stringResource(area.titleRes), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                             color = colors.text, maxLines = 2)
                        Text(stringResource(area.subRes), style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
                    }
                }
            }
        }
    }
}

/** An area's pages, as one titled list over the tab. */
@Composable
internal fun FocusAreaPage(area: FocusArea, onBack: () -> Unit, onOpen: (MoreDest) -> Unit, onTrends: () -> Unit) {
    val context = LocalContext.current
    SettingsColumn {
        PageTitle(stringResource(area.titleRes), onBack)
        if (area == FocusArea.More) {
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                HubRow(androidx.compose.material.icons.Icons.Rounded.GridView, Forge.colors.charge, stringResource(R.string.nav_trends),
                       stringResource(R.string.forge_health_trends_sub), onTrends)
            }
        }
        DestCard(area.dests.filter { it.shown(context) }, onOpen)
    }
}

/** The last seven days' Charge, Effort and Rest as small nested rings, as iOS's `weekInRings`. Opens Trends. */
@Composable
internal fun HealthWeekInRings(days: List<DailyMetric>, onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val week = days.takeLast(7)
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val rest by produceState(emptyMap<String, Double>(), week.firstOrNull()?.day, coreRevision) {
        val from = week.firstOrNull()?.day ?: return@produceState
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreRead.series(CoreRead.Metric.Rest, from, week.last().day).associate { it.day to it.value }
        }
    }
    if (week.isEmpty()) return
    val locale = Locale.getDefault()
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Text(stringResource(R.string.forge_hf_week_rings), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
             color = colors.textSecondary)
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth().clearAndSetSemantics { }) {
            week.forEach { d ->
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    MiniRings(d.recovery, d.strain, rest[d.day])
                    Spacer(Modifier.height(4.dp))
                    Text(runCatching { LocalDate.parse(d.day).dayOfWeek.getDisplayName(TextStyle.NARROW, locale) }.getOrDefault(""),
                         style = Forge.type.caption, color = colors.textSecondary, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** Charge outside, Effort in the middle, Rest inside, each a share of its own full ring. */
@Composable
private fun MiniRings(charge: Double?, effort: Double?, rest: Double?) {
    val colors = Forge.colors
    Canvas(Modifier.size(34.dp)) {
        val w = 3.dp.toPx()
        listOf(charge to colors.charge, effort to colors.effort, rest to colors.rest).forEachIndexed { i, (v, c) ->
            val inset = w / 2 + i * (w + 1.dp.toPx())
            val arc = Size(size.width - inset * 2, size.height - inset * 2)
            drawArc(c.copy(alpha = 0.18f), 0f, 360f, false, Offset(inset, inset), arc, style = Stroke(w))
            val f = ((v ?: 0.0) / 100).coerceIn(0.0, 1.0).toFloat()
            if (f > 0f) drawArc(c, -90f, 360f * f, false, Offset(inset, inset), arc, style = Stroke(w, cap = StrokeCap.Round))
        }
    }
}
