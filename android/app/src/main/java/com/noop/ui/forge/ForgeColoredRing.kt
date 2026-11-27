package com.noop.ui.forge

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import com.noop.ui.rememberPoseStill

/**
 * Fork (DX23876), 2026-11-27: the colour a coloured score ring of [metric] is drawn in (iOS
 * `StrandPalette.coloredRingTint`). Charge is a traffic light by its band from the classic readiness swatches, whatever
 * chart colours are chosen; Effort is blue, Rest light blue; a missing score is grey. The same tokens as iOS.
 */
@Composable
internal fun coloredRingTint(metric: OrganicMetric, score: Double?): Color {
    val p = ForgeTokens.StrandPalette
    if (score == null) return Forge.colors.missing
    return when (metric) {
        OrganicMetric.Charge -> when (ChargeBand.of(score)) {
            ChargeBand.Depleted -> p.cRecovery000
            ChargeBand.Low -> p.cRecovery030
            ChargeBand.Moderate -> p.cRecovery055
            ChargeBand.Primed -> p.cRecovery078
            ChargeBand.Peak -> p.cRecovery100
        }
        OrganicMetric.Effort -> p.coloredRingEffort
        OrganicMetric.Rest -> p.coloredRingRest
    }.resolve()
}

/**
 * The coloured score ring, as iOS's `ScoreRing.colored` over `FlatScoreRing`: a neutral full track and one flat arc in
 * a fixed colour from 12 o'clock with rounded ends, no gradient, no glow, no shadow at the tip. The score in the middle,
 * a percent sign after Charge and Rest. It runs no frame clock. The arc sits where the organic contour does.
 */
@Composable
internal fun ColoredScoreRing(score: Double?, metric: OrganicMetric, diameter: Dp, modifier: Modifier = Modifier,
                              format: (Double) -> String = WHOLE_NUMBER) {
    val colors = Forge.colors
    val tint = coloredRingTint(metric, score)
    val track = ForgeTokens.StrandPalette.coloredRingTrack.resolve()
    val still = rememberPoseStill()
    val ring = diameter * 0.76f
    val line = ring * 0.075f
    var appeared by remember { mutableStateOf(still) }
    LaunchedEffect(Unit) { appeared = true }
    val target = if (score == null) 0f else (score / 100.0).toFloat().coerceIn(0f, 1f)
    val filled by animateFloatAsState(if (appeared) target else 0f,
        if (still) snap() else spring(dampingRatio = 0.86f, stiffness = 120f))
    Box(modifier.size(diameter), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(ring)) {
            val stroke = line.toPx()
            val d = size.minDimension - stroke
            val topLeft = Offset((size.width - d) / 2, (size.height - d) / 2)
            val arcSize = Size(d, d)
            drawArc(track, 0f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
            if (filled > 0f) {
                rotate(-90f) {
                    drawArc(tint, 0f, maxOf(filled, 0.0001f) * 360f, false, topLeft, arcSize,
                            style = Stroke(stroke, cap = StrokeCap.Round))
                }
            }
        }
        val density = LocalDensity.current
        val numberSize = with(density) { (ring * 0.36f).toSp() }
        val unitSize = with(density) { (ring * 0.16f).toSp() }
        val text = buildAnnotatedString {
            append(if (score == null) "–" else format(score))
            if (score != null && metric != OrganicMetric.Effort) {
                withStyle(SpanStyle(fontSize = unitSize, color = colors.textSecondary)) { append("%") }
            }
        }
        Text(text, style = Forge.type.heroNumber.copy(fontSize = numberSize), color = colors.text,
             textAlign = TextAlign.Center, maxLines = 1, modifier = Modifier.padding(horizontal = line))
    }
}
