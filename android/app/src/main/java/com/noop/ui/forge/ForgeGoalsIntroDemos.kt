package com.noop.ui.forge

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Block
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.Flag
import androidx.compose.material.icons.rounded.Schedule
import androidx.compose.material.icons.rounded.Shield
import androidx.compose.material.icons.rounded.TrendingDown
import androidx.compose.material.icons.rounded.TrendingUp
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import kotlinx.coroutines.delay
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

/*
 * Fork (DX23876), Android parity: the five illustrated pages of the goals explainer after the iOS
 * `GoalsIntroSheet` demos (chain, bar, states, protected week, five kinds). The bar demo cycles through three
 * states every 2.2 s as iOS does.
 */

private const val STATE_ON_TRACK = "onTrack"

/** One state's symbol, as the Apple `GoalStatusStyle.symbol` picks them. */
private fun stateIcon(state: String): ImageVector = when (state) {
    "achieved" -> Icons.Rounded.CheckCircle
    "ahead", "onTrack" -> Icons.Rounded.TrendingUp
    "close" -> Icons.Rounded.Schedule
    "behind" -> Icons.Rounded.TrendingDown
    "outOfReach" -> Icons.Rounded.Block
    else -> Icons.Rounded.Shield
}

/** A rounded goal bar with an optional pace mark (iOS `PaceTrack`). */
@Composable
private fun PaceTrack(fraction: Float, tint: Color, height: androidx.compose.ui.unit.Dp, pace: Float? = null, modifier: Modifier = Modifier) {
    val animated by animateFloatAsState(fraction, tween(600), label = "bar")
    val colors = Forge.colors
    Box(modifier.fillMaxWidth().height(height).background(colors.inset, CircleShape)) {
        Box(Modifier.fillMaxWidth(animated.coerceIn(0f, 1f)).fillMaxHeight().background(tint, CircleShape))
        if (pace != null) {
            val p by animateFloatAsState(pace, tween(600), label = "pace")
            Box(Modifier.fillMaxWidth(p.coerceIn(0.02f, 1f)).fillMaxHeight(), contentAlignment = Alignment.CenterEnd) {
                Box(Modifier.width(3.dp).fillMaxHeight().background(colors.text, CircleShape))
            }
        }
    }
}

@Composable
internal fun GoalsIntroDemo(page: Int) {
    when (page) {
        0 -> ChainDemo()
        1 -> BarDemo()
        2 -> StatesDemo()
        3 -> ProtectedDemo()
        else -> ShapesDemo()
    }
}

@Composable
private fun ChainDemo() {
    val rows = listOf(Icons.Rounded.Flag to R.string.forge_gd_chain1, Icons.Rounded.CalendarMonth to R.string.forge_gd_chain2,
                      Icons.Rounded.Schedule to R.string.forge_gd_chain3, Icons.Rounded.CheckCircle to R.string.forge_gd_chain4)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        rows.forEachIndexed { i, (icon, text) ->
            Row(Modifier.padding(start = (18 * i).dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(icon, null, tint = Forge.colors.accent, modifier = Modifier.size(16.dp))
                Text(stringResource(text), style = Forge.type.footnote, color = Forge.colors.text)
            }
        }
    }
}

@Composable
private fun BarDemo() {
    var demo by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(2_200); demo = (demo + 1) % 3 } }
    // (bar, pace mark, state) for the three steps, as the Apple `trackDemo`.
    val steps = listOf(Triple(0.2f, 0.45f, "close"), Triple(0.55f, 0.45f, STATE_ON_TRACK), Triple(1f, 0.8f, "achieved"))
    val (bar, pace, state) = steps[demo]
    val tint = stateColor(state)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.DirectionsRun, null, tint = Forge.colors.text, modifier = Modifier.size(18.dp))
            Text(stringResource(R.string.forge_gd_runs), style = Forge.type.subhead, color = Forge.colors.text,
                 modifier = Modifier.padding(start = 6.dp).weight(1f))
            Icon(stateIcon(state), null, tint = tint, modifier = Modifier.size(14.dp))
            Text(stateWord(state), style = Forge.type.footnote, color = tint, modifier = Modifier.padding(start = 4.dp))
        }
        PaceTrack(bar, tint, 10.dp, pace = if (state == "achieved") null else pace)
        Text(stringResource(when (state) { "close" -> R.string.forge_gd_t_close; STATE_ON_TRACK -> R.string.forge_gd_t_ahead
                                          else -> R.string.forge_gd_t_done }),
             style = Forge.type.caption, color = Forge.colors.textSecondary)
    }
}

@Composable
private fun StatesDemo() {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        listOf("achieved", "onTrack", "close", "behind", "outOfReach", "protected").forEach { state ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(stateIcon(state), null, tint = stateColor(state), modifier = Modifier.size(14.dp))
                Text(stateWord(state), style = Forge.type.footnote, color = stateColor(state))
            }
        }
    }
}

@Composable
private fun ProtectedDemo() {
    val colors = Forge.colors
    val green = stateColor("achieved")
    // Met, no data (ill), no data, no data, met, rest, met: the Apple `DayDotStrip` sample week.
    val week = listOf(1, 0, 0, 0, 1, 2, 1)
    val letters = remember { (1..7).map { DayOfWeek.of(it).getDisplayName(TextStyle.NARROW, Locale.getDefault()) } }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            week.forEachIndexed { i, kind ->
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Box(Modifier.size(20.dp).background(if (kind == 1) green else if (kind == 2) green.copy(alpha = 0.35f) else colors.inset, CircleShape))
                    Text(letters[i], style = Forge.type.caption, color = colors.textTertiary)
                }
            }
        }
        Row(Modifier.fillMaxWidth().height(34.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Bottom) {
            listOf(1f to green, 0.85f to green, 0.3f to colors.accent.copy(alpha = 0.45f), 1f to green).forEach { (f, c) ->
                Box(Modifier.weight(1f).fillMaxHeight(f).background(c, RoundedCornerShape(4.dp)))
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(Icons.Rounded.Shield, null, tint = colors.accent, modifier = Modifier.size(14.dp))
            Text(stringResource(R.string.forge_gd_protected), style = Forge.type.caption, color = colors.accent)
        }
    }
}

@Composable
private fun ShapesDemo() {
    val colors = Forge.colors
    val green = stateColor("achieved")
    @Composable fun row(text: Int, visual: @Composable () -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(stringResource(text), style = Forge.type.caption, color = colors.text, maxLines = 1, modifier = Modifier.weight(1f))
            Box(Modifier.width(84.dp), contentAlignment = Alignment.CenterStart) { visual() }
        }
    }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        row(R.string.forge_gd_s1) { PaceTrack(0.64f, green, 6.dp) }
        row(R.string.forge_gd_s2) { PaceTrack(0.2f, green, 6.dp) }
        row(R.string.forge_gd_s3) { PaceTrack(0.84f, green, 6.dp) }
        row(R.string.forge_gd_s4) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(true, true, false, true).forEach { kept ->
                    Box(Modifier.size(12.dp).background(if (kept) green else colors.inset, CircleShape))
                }
            }
        }
        row(R.string.forge_gd_s5) {
            Row(Modifier.height(18.dp), horizontalArrangement = Arrangement.spacedBy(3.dp), verticalAlignment = Alignment.Bottom) {
                listOf(6.8f, 7.2f, 7.9f, 7.4f, 8.1f, 7.6f, 7.3f).forEach { v ->
                    Box(Modifier.width(7.dp).fillMaxHeight(v / 8.1f).background(colors.accent, RoundedCornerShape(2.dp)))
                }
            }
        }
    }
}
