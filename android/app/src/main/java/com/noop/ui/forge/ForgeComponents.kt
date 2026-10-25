package com.noop.ui.forge

import androidx.compose.foundation.BorderStroke
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

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

/** A key metric tile: icon plate, small caps label, the value with its unit. */
@Composable
fun MetricTile(icon: ImageVector, tint: Color, label: String, value: String?, unit: String?, noData: String,
               modifier: Modifier = Modifier, delta: String? = null) {
    val colors = Forge.colors
    ForgeCard(modifier, contentPadding = 14.dp) {
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
                    horizontalArrangement = Arrangement.spacedBy(3.dp)) {
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
                             .padding(horizontal = 5.dp, vertical = 2.dp))
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
