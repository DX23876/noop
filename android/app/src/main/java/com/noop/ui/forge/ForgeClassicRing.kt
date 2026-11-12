package com.noop.ui.forge

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import com.noop.ui.rememberPoseStill

/**
 * Fork (DX23876), Android parity 2026-11-12: the score ring style the wearer chose (iOS `ScoreRingStyle`, Settings,
 * Motion, Rings): the living organic ring, or a still classic ring like Apple's. Same key and values as iOS. Every
 * Charge, Effort and Rest ring is an [OrganicRing], which reads this, so the one setting holds everywhere.
 */
enum class ScoreRingStyle(val raw: String) {
    Organic("organic"), Classic("classic");

    companion object {
        const val KEY = "noop.scoreRingStyle"
        fun resolve(raw: String?) = entries.firstOrNull { it.raw == raw } ?: Organic

        var current by mutableStateOf(Organic)
            private set

        fun load(context: android.content.Context) {
            current = resolve(context.getSharedPreferences(com.noop.ui.NoopPrefs.NAME, android.content.Context.MODE_PRIVATE)
                .getString(KEY, null))
        }

        fun set(context: android.content.Context, style: ScoreRingStyle) {
            context.getSharedPreferences(com.noop.ui.NoopPrefs.NAME, android.content.Context.MODE_PRIVATE).edit()
                .putString(KEY, style.raw).apply()
            current = style
        }
    }
}

/**
 * The classic score ring, as iOS's `ScoreRing.classic` over `GlowRing`: a faint track in the ring's own colour, the arc
 * from 12 o'clock deepening towards its tip, a soft shadow under the tip, the score in the middle. It runs no frame
 * clock. The arc sits where the organic contour does, a little inside the ring's square.
 */
@Composable
internal fun ClassicScoreRing(score: Double?, tint: Color, diameter: Dp, modifier: Modifier = Modifier,
                              format: (Double) -> String = WHOLE_NUMBER) {
    val colors = Forge.colors
    val still = rememberPoseStill()
    val ring = diameter * 0.76f
    val line = ring * 0.09f
    var appeared by remember { mutableStateOf(still) }
    LaunchedEffect(Unit) { appeared = true }
    val target = if (score == null) 0f else (score / 100.0).toFloat().coerceIn(0f, 1f)
    val filled by animateFloatAsState(if (appeared) target else 0f,
        if (still) snap() else spring(dampingRatio = 0.86f, stiffness = 120f))
    val shown by animateFloatAsState(if (appeared) (score ?: 0.0).toFloat() else 0f,
        if (still) snap() else tween(850, easing = FastOutSlowInEasing))
    val trackAlpha = if (colors.dark) 0.2f else 0.16f
    val shadowAlpha = if (colors.dark) 0.45f else 0.22f
    Box(modifier.size(diameter), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(ring)) {
            val stroke = line.toPx()
            val d = size.minDimension - stroke
            val topLeft = Offset((size.width - d) / 2, (size.height - d) / 2)
            val arcSize = Size(d, d)
            drawArc(tint.copy(alpha = trackAlpha), 0f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
            if (filled > 0f) {
                val sweep = maxOf(filled, 0.0001f) * 360f
                rotate(-90f) {
                    drawArc(Brush.sweepGradient(0f to tint.copy(alpha = 0.62f), filled.coerceAtLeast(0.01f) to tint,
                                                center = center), 0f, sweep, false, topLeft, arcSize,
                            style = Stroke(stroke, cap = StrokeCap.Round))
                }
                // The tip: a disc in the ring's colour with a soft shadow, so a full ring still shows where it ends.
                val angle = Math.toRadians((sweep - 90f).toDouble())
                val r = d / 2
                val tip = Offset(center.x + (r * kotlin.math.cos(angle)).toFloat(), center.y + (r * kotlin.math.sin(angle)).toFloat())
                drawCircle(Color.Black.copy(alpha = shadowAlpha * 0.5f), radius = stroke / 2 + stroke * 0.22f, center = tip)
                drawCircle(tint, radius = stroke / 2, center = tip)
            }
        }
        val fontSize = with(LocalDensity.current) { (ring * 0.36f).toSp() }
        Text(if (score == null) "–" else format(shown.toDouble()), style = Forge.type.heroNumber.copy(fontSize = fontSize),
             color = colors.text, textAlign = TextAlign.Center, maxLines = 1, modifier = Modifier.padding(horizontal = line))
    }
}
