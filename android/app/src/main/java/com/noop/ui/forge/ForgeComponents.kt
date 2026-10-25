package com.noop.ui.forge

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.noop.ui.rememberPoseStill
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * A glass card: on Android 12 and later the scene behind it, blurred, under a translucent surface tint, as iOS
 * glass looks; earlier versions get a nearly opaque surface instead, since they cannot blur. A hairline rim and
 * the card radius either way.
 */
@Composable
fun ForgeCard(modifier: Modifier = Modifier, radius: Dp = ForgeMetrics.cardRadius,
              fill: Color = Forge.colors.surface.copy(alpha = if (Forge.colors.dark) 0.55f else 0.6f),
              contentPadding: Dp = ForgeMetrics.cardPadding,
              content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(radius)
    val glass = LocalSceneGlass.current
    val blur = glass != null && blurSupported
    val position = remember { mutableStateOf(Offset.Zero) }
    Box(modifier.clip(shape).onGloballyPositioned { position.value = it.positionInWindow() }) {
        if (blur && glass != null) {
            Box(Modifier.matchParentSize().graphicsLayer {
                renderEffect = BlurEffect(60f, 60f, TileMode.Clamp)
                clip = true
            }.drawBehind { with(glass) { drawScene(position.value) } })
        }
        Column(
            Modifier.fillMaxWidth().background(if (blur) fill else fill.copy(alpha = maxOf(fill.alpha, 0.92f)))
                .border(BorderStroke(ForgeMetrics.hairline, Forge.colors.heroBorder), shape)
                .padding(contentPadding),
            content = content,
        )
    }
}

/** The Charge band a score falls in (`ChargeBand.of`): below 25, 50, 70 and 88. */
enum class ChargeBand { Depleted, Low, Moderate, Primed, Peak;
    companion object {
        fun of(score: Double): ChargeBand = when {
            score < 25 -> Depleted
            score < 50 -> Low
            score < 70 -> Moderate
            score < 88 -> Primed
            else -> Peak
        }
    }
}

/** The ring colour of a Charge score: its band's stop on the recovery ramp (`chargeRingColor`). */
fun ForgeColors.chargeRing(score: Double): Color = recoveryStops[ChargeBand.of(score).ordinal].second

/**
 * The organic score ring of the Today hero: a softly wobbling band of light in [tint] with sparks drifting in it,
 * the score in the middle. On Android 12 and later the band is blurred into a real glow, as the iOS ring is;
 * earlier versions approximate it with widening, fading strokes. With no score the ring is dim and shows a dash.
 */
@Composable
fun OrganicRing(score: Double?, tint: Color, diameter: Dp, modifier: Modifier = Modifier) {
    val colors = Forge.colors
    val color = if (score == null) colors.missing else tint
    val alpha = if (score == null) 0.45f else 1f
    // Battery saver and reduced motion pose the ring still, as they still the iOS rings (the frame loop is the
    // cost, not the picture).
    val phase = if (rememberPoseStill()) 0f else {
        val moving by rememberInfiniteTransition(label = "ring").animateFloat(
            initialValue = 0f, targetValue = (2 * PI).toFloat(),
            animationSpec = infiniteRepeatable(tween(16_000, easing = LinearEasing), RepeatMode.Restart),
            label = "phase",
        )
        moving
    }
    fun ring(c: Offset, r: Float, shift: Float, depth: Float): Path = Path().apply {
        val steps = 160
        for (i in 0..steps) {
            val a = (i.toFloat() / steps) * 2 * PI.toFloat()
            val wobble = 1f + depth * (0.035f * sin(5 * a + phase + shift) +
                0.022f * sin(8 * a - 1.3f * phase + shift) + 0.012f * sin(13 * a + 0.7f * phase))
            val p = Offset(c.x + r * wobble * cos(a), c.y + r * wobble * sin(a))
            if (i == 0) moveTo(p.x, p.y) else lineTo(p.x, p.y)
        }
        close()
    }
    Box(modifier.size(diameter), contentAlignment = Alignment.Center) {
        // The glow: a wide band and its halo, blurred where the platform can.
        Canvas(Modifier.fillMaxSize().graphicsLayer {
            if (blurSupported) renderEffect = BlurEffect(size.minDimension * 0.06f, size.minDimension * 0.06f,
                                                         TileMode.Decal)
        }) {
            val c = Offset(size.width / 2, size.height / 2)
            val r = size.minDimension * 0.36f
            drawCircle(Brush.radialGradient(listOf(color.copy(alpha = 0.10f * alpha), color.copy(alpha = 0.22f * alpha),
                                                   Color.Transparent), c, r * 1.3f), radius = r * 1.3f, center = c)
            val band = if (blurSupported) listOf(0.16f to 0.55f, 0.08f to 0.7f) else
                listOf(0.24f to 0.04f, 0.16f to 0.07f, 0.10f to 0.12f, 0.06f to 0.22f)
            val main = ring(c, r, 0f, 1f)
            band.forEach { (w, a) ->
                drawPath(main, color.copy(alpha = a * alpha),
                         style = Stroke(width = size.minDimension * w, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
        }
        // The crisp strands and sparks over the glow.
        Canvas(Modifier.fillMaxSize()) {
            val c = Offset(size.width / 2, size.height / 2)
            val r = size.minDimension * 0.36f
            listOf(2.1f to 1.7f, 4.2f to 2.3f, 1.0f to 2.9f, 5.3f to 1.2f).forEach { (shift, depth) ->
                drawPath(ring(c, r, shift, depth), lerp(color, Color.White, 0.25f).copy(alpha = 0.45f * alpha),
                         style = Stroke(width = size.minDimension * 0.008f))
            }
            drawPath(ring(c, r, 0f, 1f), lerp(color, Color.White, 0.45f).copy(alpha = 0.9f * alpha),
                     style = Stroke(width = size.minDimension * 0.014f, join = StrokeJoin.Round))
            if (score != null) {
                for (k in 0 until 18) {
                    val a = k * 0.349f + phase * (if (k % 2 == 0) 0.25f else -0.18f)
                    val rr = r * (0.84f + 0.14f * sin(k * 2.3f + phase * 1.4f))
                    val dot = size.minDimension * (0.006f + 0.006f * ((k * 7) % 3))
                    drawCircle(lerp(color, Color.White, 0.6f).copy(alpha = 0.35f + 0.45f * ((k % 4) / 3f)),
                               radius = dot, center = Offset(c.x + rr * cos(a), c.y + rr * sin(a)))
                }
            }
        }
        val fontScale = (diameter.value / 110f).coerceIn(0.85f, 2.2f)
        Text(score?.let { "%.0f".format(it) } ?: "–",
             style = Forge.type.heroNumber.copy(fontSize = Forge.type.heroNumber.fontSize * fontScale),
             color = colors.text, maxLines = 1)
    }
}

/** A key metric tile: icon plate, small caps label, the value with its unit. */
@Composable
fun MetricTile(icon: ImageVector, tint: Color, label: String, value: String?, unit: String?, noData: String,
               modifier: Modifier = Modifier, delta: String? = null) {
    val colors = Forge.colors
    ForgeCard(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(32.dp).background(tint.copy(alpha = 0.16f), RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center) {
                Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.width(ForgeMetrics.space2 + ForgeMetrics.space1))
            Text(label.uppercase(), style = Forge.type.overline, color = colors.textSecondary, maxLines = 1,
                 overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.padding(top = ForgeMetrics.space2 + ForgeMetrics.space1))
        if (value == null) {
            Text(noData, style = Forge.type.subhead, color = colors.textTertiary, maxLines = 1)
        } else {
            Row(verticalAlignment = Alignment.Bottom) {
                // The value and unit give way first; the change chip always shows whole.
                Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(value, style = Forge.type.title1, color = colors.text, maxLines = 1, softWrap = false)
                    if (unit != null) {
                        Text(unit, style = Forge.type.subhead, color = colors.textSecondary, maxLines = 1,
                             overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 4.dp))
                    }
                }
                if (delta != null) {
                    Text(delta, style = Forge.type.captionNumber, color = colors.textSecondary, maxLines = 1,
                         softWrap = false,
                         modifier = Modifier.padding(bottom = 4.dp)
                             .background(colors.inset.copy(alpha = 0.6f), RoundedCornerShape(8.dp))
                             .padding(horizontal = 6.dp, vertical = 2.dp))
                }
            }
        }
    }
}

/** Small caps section header, as the iOS screens title their sections. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier) {
    Text(text.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary,
         modifier = modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space1))
}
