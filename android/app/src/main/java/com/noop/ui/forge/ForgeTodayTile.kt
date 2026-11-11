package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.core.CoreTile
import com.noop.ui.KeyMetric

/**
 * Fork (DX23876), Forge parity 2026-11: a Today tile drawn as iOS's `TodayMetricTile` in the new design draws it: the
 * tinted icon plate and the name on one line that shrinks rather than wraps, the figure at medium weight with its unit,
 * the change chip beside the figure (on the caption line in three columns), the quiet caption, and the trend's space
 * kept even without a trend, so every tile of a row has the same layout. The surface fills the whole slot, so a row
 * of tiles is as tall as its tallest. Analysis migration required: no.
 */
@Composable
internal fun ForgeTodayTile(icon: ImageVector, tint: Color, label: String, value: String?, unit: String, caption: String?,
                            noData: String, dense: Boolean, modifier: Modifier = Modifier, delta: String? = null,
                            deltaTone: String? = null, trend: List<Double>? = null,
                            overlay: (@Composable () -> Unit)? = null) {
    val colors = Forge.colors
    val sparkHeight = if (dense) 22.dp else 28.dp
    Box(modifier.heightIn(min = ForgeTokens.NoopMetrics.tileHeight.dp)) {
        ForgeCard(Modifier.fillMaxWidth().fillMaxHeight(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            Column(Modifier.fillMaxWidth().padding(horizontal = if (dense) 12.dp else 14.dp, vertical = if (dense) 11.dp else 12.dp),
                   verticalArrangement = Arrangement.spacedBy(if (dense) 5.dp else 6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(if (dense) 26.dp else 30.dp).background(tint.copy(alpha = 0.13f), CircleShape),
                        contentAlignment = Alignment.Center) {
                        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(if (dense) 13.dp else 15.dp))
                    }
                    Spacer(Modifier.width(if (dense) 6.dp else 8.dp))
                    ShrinkText(label, (if (dense) Forge.type.caption else Forge.type.footnote).copy(fontWeight = FontWeight.SemiBold),
                               colors.textSecondary, minScale = 0.72f, modifier = Modifier.weight(1f))
                }
                Row(verticalAlignment = Alignment.Bottom) {
                    val number = Forge.type.bodyNumber.copy(fontSize = if (dense) Forge.type.title2.fontSize else Forge.type.title1.fontSize,
                                                            fontWeight = FontWeight.Medium, color = colors.text)
                    Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom) {
                        // An empty tile keeps the figure's line, so it stays as tall as its neighbours.
                        ShrinkText(value ?: " ", number, colors.text, minScale = 0.58f, modifier = Modifier.weight(1f, fill = false))
                        if (value != null && unit.isNotEmpty()) {
                            Text(" " + unit, style = Forge.type.caption, color = colors.textSecondary, maxLines = 1,
                                 modifier = Modifier.padding(bottom = 3.dp))
                        }
                    }
                    if (delta != null && value != null && !dense) DeltaChip(delta, deltaTone)
                }
                val line = if (value == null) caption ?: noData else caption
                if (dense && delta != null && value != null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        DeltaChip(delta, deltaTone)
                        if (line != null) { Spacer(Modifier.width(5.dp)); ShrinkText(line, Forge.type.footnote, colors.textSecondary, 0.7f, Modifier.weight(1f)) }
                    }
                } else if (line != null) {
                    ShrinkText(line, Forge.type.footnote, colors.textSecondary, 0.7f, Modifier.fillMaxWidth())
                }
                if (trend != null && trend.size > 1) KeyTileSpark(trend, tint, sparkHeight)
                else Spacer(Modifier.height(sparkHeight))
            }
        }
        overlay?.invoke()
    }
}

/** The change chip: green, yellow or red by what the move means for the body (`MeasureTileReading`), grey without. */
@Composable
private fun DeltaChip(text: String, tone: String?) {
    val colors = Forge.colors
    val color = when (tone) {
        "good" -> colors.charge
        "small" -> ForgeTokens.StrandPalette.statusWarningForeground.resolve()
        "large" -> ForgeTokens.StrandPalette.statusCritical.resolve()
        else -> colors.textTertiary
    }
    Text(text, style = Forge.type.captionNumber.copy(fontWeight = FontWeight.SemiBold), color = color, maxLines = 1, softWrap = false,
         modifier = Modifier.background(color.copy(alpha = 0.12f), RoundedCornerShape(8.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
}

/** One line that shrinks down to [minScale] of its size before it is cut, as SwiftUI's `minimumScaleFactor`. */
@Composable
private fun ShrinkText(text: String, style: TextStyle, color: Color, minScale: Float, modifier: Modifier = Modifier) {
    var scale by remember(text, style) { mutableFloatStateOf(1f) }
    Text(text, style = style.copy(fontSize = style.fontSize * scale), color = color, maxLines = 1, softWrap = false,
         modifier = modifier, onTextLayout = { if (it.hasVisualOverflow && scale > minScale) scale = maxOf(minScale, scale * 0.92f) })
}

/** The shared catalog key a Today measure goes by (`MeasureTileReading`). */
internal fun KeyMetric.catalogKey(): String = when (this) {
    KeyMetric.RESTING_HR -> "rhr"
    KeyMetric.BLOOD_OXYGEN -> "spo2"
    KeyMetric.RESPIRATORY -> "resp_rate"
    KeyMetric.SKIN_TEMP -> "skin_temp"
    KeyMetric.CALORIES -> "active_kcal"
    else -> raw
}

/** The change and its tone for a tile's values, from the shared core. Null while it loads or without a week. */
@Composable
internal fun rememberTileDelta(key: String, values: List<Double>?): CoreTile.Delta? {
    val v = values.orEmpty()
    val state = androidx.compose.runtime.produceState<CoreTile.Delta?>(null, key, v) {
        value = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { runCatching { CoreTile.delta(key, v) }.getOrNull() }
    }
    return state.value
}
