package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
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
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.R

// Pictures that explain a figure, opened from its info symbol, after iOS `ForgeExplainerDrawings.swift`. Each is drawn
// rather than shipped as an image, so it follows light, dark and the colour profile and its words are translated. They
// illustrate how a measure works; none shows the wearer's own data.

/** iOS `ExplainerInfoButton`: the info symbol that opens [picture] with its title and short text as a sheet. */
@Composable
internal fun ExplainerInfoButton(title: Int, text: Int, picture: @Composable () -> Unit) {
    var open by remember { mutableStateOf(false) }
    IconButton(onClick = { open = true }) {
        Icon(Icons.Outlined.Info, contentDescription = stringResource(R.string.forge_ex_what_this_means),
             tint = Forge.colors.textSecondary, modifier = Modifier.size(20.dp))
    }
    if (open) ExplainerSheet(stringResource(title), stringResource(text), onDismiss = { open = false }, picture = picture)
}

/** iOS `ExplainerSheet`: the picture, its title and its text, with Done. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ExplainerSheet(title: String, text: String, onDismiss: () -> Unit, picture: @Composable () -> Unit) {
    val colors = Forge.colors
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = colors.canvas) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding()
                   .padding(horizontal = ForgeMetrics.screenPadding).padding(bottom = ForgeMetrics.space4),
               verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.forge_set_done), style = Forge.type.body.copy(fontWeight = FontWeight.SemiBold),
                         color = colors.accent)
                }
            }
            picture()
            Text(title, style = Forge.type.title2, color = colors.text)
            Text(text, style = Forge.type.body, color = colors.textSecondary)
        }
    }
}

/** iOS `ExplainerPanel`: the soft tinted panel every explaining picture sits on, silent for TalkBack. */
@Composable
private fun ExplainerPanel(tint: Color, height: Dp = 176.dp, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth().height(height)
            .background(Brush.linearGradient(listOf(tint.copy(alpha = 0.18f), tint.copy(alpha = 0.05f))), RoundedCornerShape(22.dp))
            .padding(16.dp).clearAndSetSemantics { }) { content() }
}

/** iOS `ExplainerNightStages`: a made-up night as four named lanes, deep early, REM late, short wakings between. */
@Composable
internal fun ExplainerNightStages() {
    val c = Forge.colors
    val lanes = listOf(c.sleepAwake, c.sleepRem, c.sleepLight, c.sleepDeep)
    val blocks = listOf(2 to 0.05f, 3 to 0.13f, 2 to 0.05f, 1 to 0.03f, 2 to 0.07f, 3 to 0.1f, 2 to 0.06f, 1 to 0.06f,
                        0 to 0.012f, 2 to 0.09f, 3 to 0.03f, 2 to 0.07f, 1 to 0.1f, 0 to 0.012f, 2 to 0.05f, 1 to 0.086f)
    ExplainerPanel(c.rest, 190.dp) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.fillMaxHeight()) {
                listOf(R.string.forge_stage_awake, R.string.forge_stage_rem, R.string.forge_stage_light, R.string.forge_stage_deep)
                    .forEach { name ->
                        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                            Text(stringResource(name), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold),
                                 color = c.text, maxLines = 1)
                        }
                    }
            }
            Canvas(Modifier.weight(1f).fillMaxHeight()) {
                val laneH = size.height / 4
                val unit = size.width / blocks.sumOf { it.second.toDouble() }.toFloat()
                var x = 0f
                blocks.forEach { (lane, length) ->
                    val w = (length * unit - 1f).coerceAtLeast(3f)
                    drawRoundRect(lanes[lane], Offset(x, lane * laneH + 5.dp.toPx()), Size(w, laneH - 10.dp.toPx()),
                                  CornerRadius(4.dp.toPx(), 4.dp.toPx()))
                    x += length * unit
                }
            }
        }
    }
}

/** iOS `ExplainerEnergyBars`: burned as resting plus active, beside what was eaten. */
@Composable
internal fun ExplainerEnergyBars() {
    val c = Forge.colors
    val resting = ForgeTokens.StrandPalette.forgeEnergyResting.resolve()
    val active = ForgeTokens.StrandPalette.forgeEnergyActive.resolve()
    ExplainerPanel(active, 150.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            EnergyRow(R.string.forge_ex_burned) {
                Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                    EnergySegment(R.string.forge_ex_resting, resting, Modifier.weight(0.66f))
                    EnergySegment(R.string.forge_ex_active, active, Modifier.weight(0.34f))
                }
            }
            EnergyRow(R.string.forge_ex_eaten) {
                Box(Modifier.fillMaxWidth(0.86f).fillMaxHeight().background(c.text, CircleShape))
            }
        }
    }
}

@Composable
private fun EnergyRow(name: Int, bar: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(stringResource(name), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
        Box(Modifier.fillMaxWidth().height(26.dp)) { bar() }
    }
}

@Composable
private fun EnergySegment(name: Int, tint: Color, modifier: Modifier) {
    Box(modifier.fillMaxHeight().background(tint, CircleShape), contentAlignment = Alignment.Center) {
        Text(stringResource(name), style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Color.White,
             maxLines = 1, modifier = Modifier.padding(horizontal = 6.dp))
    }
}

/** iOS `ExplainerHeartbeats`: four beats with unequal gaps between them; that spread is what HRV measures. */
@Composable
internal fun ExplainerHeartbeats() {
    val c = Forge.colors
    val tint = c.charge
    val beats = listOf(0.1f, 0.33f, 0.6f, 0.81f)
    val gaps = listOf("820 ms", "910 ms", "760 ms")
    ExplainerPanel(tint) {
        BoxWithConstraints(Modifier.fillMaxWidth().fillMaxHeight()) {
            val w = maxWidth
            Canvas(Modifier.fillMaxWidth().height(maxHeight - 34.dp)) {
                val mid = size.height / 2 + size.height * 0.22f
                val tall = size.height * 0.62f
                val unit = size.width * 0.018f
                val path = Path().apply {
                    moveTo(0f, mid)
                    beats.forEach { b ->
                        val x = b * size.width
                        lineTo(x - unit * 3.2f, mid)
                        quadraticBezierTo(x - unit * 2.3f, mid - tall * 0.13f, x - unit * 1.4f, mid)
                        lineTo(x - unit * 0.6f, mid + tall * 0.12f)
                        lineTo(x, mid - tall)
                        lineTo(x + unit * 0.7f, mid + tall * 0.2f)
                        lineTo(x + unit * 1.5f, mid)
                        quadraticBezierTo(x + unit * 2.8f, mid - tall * 0.2f, x + unit * 4f, mid)
                    }
                    lineTo(size.width, mid)
                }
                drawPath(path, tint.copy(alpha = 0.3f), style = Stroke(width = 6.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
                drawPath(path, tint, style = Stroke(width = 2.2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            gaps.forEachIndexed { i, gap ->
                val a = w * beats[i]
                val b = w * beats[i + 1]
                Column(Modifier.padding(start = a + 3.dp, top = maxHeight - 26.dp).width(b - a - 6.dp),
                       horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Box(Modifier.fillMaxWidth().height(7.dp)) {
                        Box(Modifier.fillMaxWidth().height(1.dp).align(Alignment.Center).background(c.textTertiary))
                        Box(Modifier.width(1.dp).fillMaxHeight().align(Alignment.CenterStart).background(c.textTertiary))
                        Box(Modifier.width(1.dp).fillMaxHeight().align(Alignment.CenterEnd).background(c.textTertiary))
                    }
                    Text(gap, style = Forge.type.captionNumber.copy(fontWeight = FontWeight.SemiBold), color = c.text,
                         maxLines = 1, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** Which score [ExplainerScoreInputs] explains, with the inputs iOS names for it. */
internal enum class ExplainedScore(val title: Int, val inputs: List<Int>) {
    Charge(R.string.forge_charge, listOf(R.string.forge_ex_in_hrv, R.string.forge_ex_in_rhr, R.string.forge_ex_in_sleep,
                                         R.string.forge_ex_in_breathing, R.string.forge_ex_in_skin)),
    Effort(R.string.forge_effort, listOf(R.string.forge_ex_in_hr, R.string.forge_ex_in_time, R.string.forge_ex_in_strength)),
    Rest(R.string.forge_rest, listOf(R.string.forge_ex_in_how_long, R.string.forge_ex_in_how_well,
                                     R.string.forge_ex_in_how_regular, R.string.forge_ex_in_deep_rem)),
}

/** iOS `ExplainerScoreInputs`: the score's inputs on the left, each a line curving into the score's ring. */
@Composable
internal fun ExplainerScoreInputs(score: ExplainedScore) {
    val c = Forge.colors
    val tint = when (score) { ExplainedScore.Charge -> c.charge; ExplainedScore.Effort -> c.effort; ExplainedScore.Rest -> c.rest }
    ExplainerPanel(tint) {
        BoxWithConstraints(Modifier.fillMaxWidth().fillMaxHeight()) {
            val w = maxWidth; val h = maxHeight
            val ring = minOf(h * 0.74f, 112.dp)
            val startX = w * 0.46f
            val rowH = h / score.inputs.size
            Canvas(Modifier.fillMaxWidth().fillMaxHeight()) {
                val r = ring.toPx(); val cx = size.width - r / 2 - 4.dp.toPx(); val cy = size.height / 2
                val sx = startX.toPx(); val rh = size.height / score.inputs.size
                score.inputs.indices.forEach { i ->
                    val y = rh * (i + 0.5f)
                    val path = Path().apply {
                        moveTo(sx, y)
                        cubicTo(sx + (cx - sx) * 0.4f, y, sx + (cx - sx) * 0.4f, cy, cx - r / 2 - 2.dp.toPx(), cy)
                    }
                    drawPath(path, tint.copy(alpha = 0.55f), style = Stroke(width = 1.6.dp.toPx(), cap = StrokeCap.Round))
                }
                val stroke = 9.dp.toPx()
                val tl = Offset(cx - r / 2, cy - r / 2)
                drawArc(tint.copy(alpha = 0.18f), 0f, 360f, false, tl, Size(r, r), style = Stroke(stroke))
                drawArc(tint.copy(alpha = 0.3f), -90f, 0.72f * 360f, false, tl, Size(r, r), style = Stroke(stroke * 1.8f, cap = StrokeCap.Round))
                drawArc(tint, -90f, 0.72f * 360f, false, tl, Size(r, r), style = Stroke(stroke, cap = StrokeCap.Round))
            }
            Box(Modifier.padding(start = w - ring - 4.dp, top = (h - ring) / 2).size(ring), contentAlignment = Alignment.Center) {
                Text(stringResource(score.title), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = c.text,
                     maxLines = 1, modifier = Modifier.padding(horizontal = 11.dp))
            }
            score.inputs.forEachIndexed { i, input ->
                Box(Modifier.padding(top = rowH * i).width(startX - 4.dp).height(rowH), contentAlignment = Alignment.CenterStart) {
                    Text(stringResource(input), style = Forge.type.footnote.copy(fontWeight = FontWeight.Medium), color = c.text, maxLines = 1)
                }
            }
        }
    }
}
