package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Fork (DX23876), Forge parity 2026-11: Today's "Last night" card in the new design, as iOS's `ForgeLastNightWidget`:
 * the newest night of the last three days, its hours asleep large with small units, the bed and wake times, a strip
 * of the stages in proportion and the deep, light and REM totals under it. Tapping opens the Sleep tab.
 */
@Composable
internal fun TodayLastNightForge(onOpen: () -> Unit) {
    val context = LocalContext.current
    val colors = Forge.colors
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    val night by produceState<CoreRead.Night?>(null, coreRevision) {
        value = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            val now = System.currentTimeMillis() / 1000
            CoreRead.nights(now - 3 * 86_400, now + 86_400).maxByOrNull { it.endTs }
        }
    }
    val m = night?.minutes.orEmpty()
    val deep = m["deep"] ?: 0.0
    val light = m["light"] ?: 0.0
    val rem = m["rem"] ?: 0.0
    val awake = m["wake"] ?: 0.0
    val asleep = Math.round(deep + light + rem).toInt()
    ForgeCard(Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_w_last_night), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = colors.text, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = colors.textTertiary)
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        val n = night
        if (n == null || asleep <= 0) {
            Text(stringResource(R.string.forge_ln_none), style = Forge.type.caption, color = colors.textSecondary)
        } else {
            val figure = Forge.type.title1.copy(fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
            val unit = Forge.type.footnote.copy(fontWeight = FontWeight.Medium)
            Row(verticalAlignment = Alignment.Bottom) {
                Text((asleep / 60).toString(), style = figure, color = colors.text)
                Text(stringResource(R.string.forge_goals_u_h), style = unit, color = colors.textSecondary,
                     modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
                Text((asleep % 60).toString(), style = figure, color = colors.text, modifier = Modifier.padding(start = 8.dp))
                Text(stringResource(R.string.forge_goals_u_min), style = unit, color = colors.textSecondary,
                     modifier = Modifier.padding(start = 4.dp, bottom = 4.dp))
                Spacer(Modifier.weight(1f).width(8.dp))
                Text(stringResource(R.string.l10n_sleep_screen_deleted_sleep_window_range_7bc5f027,
                                    clockOf(n.startTs), clockOf(n.endTs)),
                     style = Forge.type.caption, color = colors.textSecondary, maxLines = 1,
                     modifier = Modifier.padding(bottom = 6.dp))
            }
            Spacer(Modifier.height(ForgeMetrics.space2))
            StageStrip(listOf(deep to colors.sleepDeep, light to colors.sleepLight, rem to colors.sleepRem, awake to colors.sleepAwake))
            Spacer(Modifier.height(ForgeMetrics.space2))
            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                StageLegend(stringResource(R.string.forge_stage_deep), deep, colors.sleepDeep)
                StageLegend(stringResource(R.string.forge_stage_light), light, colors.sleepLight)
                StageLegend(stringResource(R.string.forge_stage_rem), rem, colors.sleepRem)
            }
        }
    }
}

@Composable
private fun clockOf(ts: Long): String =
    java.time.Instant.ofEpochSecond(ts).atZone(java.time.ZoneId.systemDefault()).format(rememberClockFormatter())

/** The stages side by side in proportion, as iOS's `ForgeStageStrip`: 8 dp tall, 2 dp apart, at least 3 dp each. */
@Composable
private fun StageStrip(parts: List<Pair<Double, Color>>) {
    val total = parts.sumOf { it.first }.coerceAtLeast(1.0)
    BoxWithConstraints(Modifier.fillMaxWidth().height(8.dp)) {
        val usable = maxWidth - 6.dp
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            parts.filter { it.first > 0 }.forEach { (minutes, color) ->
                Box(Modifier.width(maxOf(3.dp, usable * (minutes / total).toFloat())).height(8.dp)
                        .background(color, RoundedCornerShape(3.dp)))
            }
        }
    }
}

@Composable
private fun StageLegend(name: String, minutes: Double, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Text(stringResource(R.string.forge_pair_words, name, TodayTimeline.hoursMinutes(minutes)), style = Forge.type.captionNumber, color = Forge.colors.textSecondary,
             modifier = Modifier.padding(start = 4.dp))
    }
}
