package com.noop.ui.forge

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.BatteryChargingFull
import androidx.compose.material.icons.rounded.DragHandle
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.HourglassEmpty
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.KeyboardDoubleArrowUp
import androidx.compose.material.icons.rounded.NorthEast
import androidx.compose.material.icons.rounded.SouthEast
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import java.text.NumberFormat
import kotlin.math.abs
import kotlin.math.roundToInt

// Fork (DX23876), Android parity plan 2.3: the shared building blocks of the Training Load, Strength and Cardio
// screens (iOS `TrainingDesignKit.swift` and `TrainingStatusVisuals.swift`). They take finished values; each screen
// decides what goes in them.

/** The lane colours of the Signature style (`StrandPalette.LaneColorTable.signature`), deep → colour → bright. */
private object LaneColors {
    val strengthDeep = ForgeColor(light = 0xFF064E53, dark = 0xFF086E74)
    val strength = ForgeColor(light = 0xFF0A8F97, dark = 0xFF1ED6E0)
    val strengthBright = ForgeColor(light = 0xFF0FB3BC, dark = 0xFF7CEBF0)
    val cardioDeep = ForgeColor(light = 0xFF291268, dark = 0xFF3A1A93)
    val cardio = ForgeColor(light = 0xFF440CDF, dark = 0xFF7D51F6)
    val cardioBright = ForgeColor(light = 0xFF622FEE, dark = 0xFFA98CF8)
}

/** The two training lanes and the identity each carries on every screen (`TrainingLane`). */
enum class TrainingLane { Strength, Cardio;
    val color: Color @Composable get() = (if (this == Strength) LaneColors.strength else LaneColors.cardio).resolve()
    val deep: Color @Composable get() = (if (this == Strength) LaneColors.strengthDeep else LaneColors.cardioDeep).resolve()
    val bright: Color @Composable get() = (if (this == Strength) LaneColors.strengthBright else LaneColors.cardioBright).resolve()
    val icon: ImageVector get() = if (this == Strength) Icons.Rounded.FitnessCenter else Icons.Rounded.Favorite
    val title: String @Composable get() = stringResource(if (this == Strength) R.string.forge_th_strength else R.string.forge_tl_cardio)
}

/** The palette colours the status visuals use (`StrandPalette`). */
object TrainingTint {
    val positive @Composable get() = ForgeTokens.StrandPalette.statusPositive.resolve()
    val warning @Composable get() = ForgeTokens.StrandPalette.statusWarning.resolve()
    val warningForeground @Composable get() = ForgeTokens.StrandPalette.statusWarningForeground.resolve()
    val critical @Composable get() = ForgeTokens.StrandPalette.statusCritical.resolve()
    val cyan @Composable get() = ForgeTokens.StrandPalette.metricCyan.resolve()
    val amber @Composable get() = ForgeTokens.StrandPalette.metricAmber.resolve()
    val rest @Composable get() = ForgeTokens.StrandPalette.restColor.resolve()
    val effort @Composable get() = ForgeTokens.StrandPalette.effortColor.resolve()
    val onDark @Composable get() = ForgeTokens.StrandPalette.onDarkPrimary.resolve()
}

/** A rounded number face at a size (`StrandFont.number`). */
fun numberStyle(base: TextStyle, size: Int, weight: FontWeight = FontWeight.SemiBold): TextStyle =
    base.copy(fontSize = size.sp, fontWeight = weight)

// MARK: - Bands, verdicts and pills

/** The band's colour (`RelativeLoadBand.color`): one cool-to-hot ramp. */
@Composable
fun bandColor(band: String?): Color = when (band) {
    "below" -> TrainingTint.rest
    "usual" -> TrainingTint.positive
    "higher" -> TrainingTint.cyan
    "muchHigher" -> TrainingTint.amber
    else -> Forge.colors.textTertiary
}

fun bandIcon(band: String?): ImageVector = when (band) {
    "below" -> Icons.Rounded.SouthEast
    "usual" -> Icons.Rounded.DragHandle
    "higher" -> Icons.Rounded.NorthEast
    "muchHigher" -> Icons.Rounded.KeyboardDoubleArrowUp
    else -> Icons.Rounded.HourglassEmpty
}

@Composable
fun bandLabel(band: String?): String = stringResource(when (band) {
    "below" -> R.string.forge_tl_below_usual
    "usual" -> R.string.forge_tl_about_usual
    "higher" -> R.string.forge_tl_above_usual
    "muchHigher" -> R.string.forge_tl_well_above_usual
    else -> R.string.forge_tl_no_comparison
})

/** A training status's word, glyph and colour (`TrainingStatus`). */
@Composable
fun statusLabel(status: String): String = stringResource(when (status) {
    "detraining" -> R.string.forge_tl_detraining
    "recovering" -> R.string.forge_tl_recovering
    "maintaining" -> R.string.forge_tl_maintaining
    "productive" -> R.string.forge_tl_productive
    "unproductive" -> R.string.forge_tl_unproductive
    else -> R.string.forge_tl_overreaching
})

fun statusIcon(status: String): ImageVector = when (status) {
    "detraining" -> Icons.Rounded.SouthEast
    "recovering" -> Icons.Rounded.BatteryChargingFull
    "maintaining" -> Icons.Rounded.DragHandle
    "productive" -> Icons.Rounded.NorthEast
    "unproductive" -> Icons.Rounded.Sync
    else -> Icons.Rounded.Warning
}

@Composable
fun statusColor(status: String): Color = when (status) {
    "detraining", "recovering" -> bandColor("below")
    "maintaining" -> bandColor("usual")
    "productive" -> bandColor("higher")
    "unproductive" -> TrainingTint.warning
    else -> bandColor("muchHigher")
}

/** Where a lane's week sits (`LoadPillState`). */
enum class LoadPill { Below, Usual, Higher, MuchHigher, Provisional, NoComparison, TooFewSessions;
    val hasComparison get() = this != Provisional && this != NoComparison && this != TooFewSessions
    companion object {
        fun of(band: String?, guardState: String?, provisional: Boolean = false): LoadPill = when (band) {
            "below" -> Below
            "usual" -> Usual
            "higher" -> Higher
            "muchHigher" -> MuchHigher
            else -> if (guardState == "tooFewSessions") TooFewSessions else if (provisional) Provisional else NoComparison
        }
    }
}

@Composable
fun LoadStatusPill(lane: TrainingLane, state: LoadPill) {
    val label = when (state) {
        LoadPill.Below -> bandLabel("below")
        LoadPill.Usual -> bandLabel("usual")
        LoadPill.Higher -> bandLabel("higher")
        LoadPill.MuchHigher -> bandLabel("muchHigher")
        LoadPill.Provisional -> stringResource(R.string.forge_tl_provisional)
        LoadPill.NoComparison -> stringResource(R.string.forge_tl_no_comparison)
        LoadPill.TooFewSessions -> stringResource(R.string.forge_tl_too_few_sessions)
    }
    val icon = when (state) {
        LoadPill.Below -> bandIcon("below")
        LoadPill.Usual -> bandIcon("usual")
        LoadPill.Higher -> bandIcon("higher")
        LoadPill.MuchHigher -> bandIcon("muchHigher")
        LoadPill.Provisional -> Icons.Rounded.AutoAwesome
        else -> Icons.Rounded.HourglassEmpty
    }
    val ink = if (state.hasComparison) TrainingTint.onDark else Forge.colors.textSecondary
    val background = if (state.hasComparison) Modifier.background(Brush.horizontalGradient(listOf(lane.deep, lane.color)), CircleShape)
                     else Modifier.background(Forge.colors.inset, CircleShape)
    Row(background.padding(horizontal = 10.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = ink, modifier = Modifier.size(13.dp))
        Spacer(Modifier.width(4.dp))
        Text(label, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = ink, maxLines = 1)
    }
}

/** "+18 %", "−7 %", and "0 %" for a change that rounds to nothing (`LoadFormat.signedPercent`). */
fun signedPercent(value: Double): String {
    val magnitude = abs(value).roundToInt()
    if (magnitude == 0) return "0 %"
    return "${if (value > 0) "+" else "−"}$magnitude %"
}

/** "20 Jul" in the wearer's locale (`StatusHistoryStrip.shortDate`). */
fun shortDate(day: String): String = runCatching {
    LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault()))
}.getOrDefault(day)

fun mediumDate(day: String): String = runCatching {
    LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault()))
}.getOrDefault(day)

// MARK: - Badges and surfaces

/** A filled symbol badge: the colour with a gloss from above, the glyph in white (`StatusBadge`). */
@Composable
fun StatusBadge(icon: ImageVector, color: Color, size: Dp = 32.dp, corner: Dp? = null) {
    val shape = if (corner != null) RoundedCornerShape(corner) else CircleShape
    val white = TrainingTint.onDark
    Box(Modifier.size(size).shadow(size * 0.14f, shape, ambientColor = color.copy(alpha = 0.42f),
                                   spotColor = color.copy(alpha = 0.42f))
            .background(Brush.verticalGradient(listOf(color.copy(alpha = 0.9f), color)), shape)
            .background(Brush.verticalGradient(0f to white.copy(alpha = 0.34f), 0.5f to white.copy(alpha = 0f)), shape),
        contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = white, modifier = Modifier.size(size * 0.5f))
    }
}

/** A lane-tinted hero surface (`LaneHeroSurface`). */
@Composable
private fun Modifier.laneHeroSurface(lane: TrainingLane): Modifier {
    val dark = Forge.colors.dark
    val shape = RoundedCornerShape(ForgeMetrics.cardRadius)
    val deep = lane.deep; val color = lane.color; val bright = lane.bright
    val surface = Forge.colors.surface
    return this.shadow(16.dp, shape, ambientColor = color.copy(alpha = 0.22f), spotColor = color.copy(alpha = 0.22f))
        .clip(shape)
        .drawBehind {
            drawRect(surface)
            drawRect(Brush.linearGradient(listOf(deep.copy(alpha = if (dark) 0.62f else 0.2f),
                                                 color.copy(alpha = if (dark) 0.22f else 0.08f)),
                                          start = Offset.Zero, end = Offset(size.width, size.height)))
            drawRect(Brush.radialGradient(listOf(bright.copy(alpha = if (dark) 0.28f else 0.22f), Color.Transparent),
                                          center = Offset(size.width, 0f), radius = 220.dp.toPx()))
        }
        .border(BorderStroke(1.dp, color.copy(alpha = 0.45f)), shape)
}

/**
 * A lane's headline (`LoadHeroCard`): the change against usual, its state, the measured figure behind it, and what
 * the reading rests on, over the lane's own eight-week ratio line.
 */
@Composable
fun LoadHeroCard(lane: TrainingLane, percent: Double?, state: LoadPill, figure: String?, trend: List<Double>,
                 coverage: String?, caveat: String?, note: String?, title: String? = null,
                 onClick: (() -> Unit)? = null) {
    Column(Modifier.fillMaxWidth().laneHeroSurface(lane)
               .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
               .padding(ForgeMetrics.cardPadding),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusBadge(lane.icon, lane.color, 28.dp)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(title ?: lane.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Forge.colors.text, maxLines = 1, modifier = Modifier.weight(1f))
            LoadStatusPill(lane, state)
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            if (percent != null) {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(signedPercent(percent), style = numberStyle(Forge.type.heroNumber, 42, FontWeight.Bold),
                         color = Forge.colors.text, maxLines = 1)
                    Text(stringResource(R.string.forge_tl_vs_usual), style = Forge.type.caption,
                         color = Forge.colors.textSecondary)
                }
            }
            if (trend.size >= 2) LoadBaselineTrend(lane, trend, Modifier.weight(1f))
        }
        figure?.let { Text(it, style = Forge.type.captionNumber, color = Forge.colors.text) }
        coverage?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textSecondary) }
        caveat?.let {
            Row {
                Icon(Icons.Rounded.Warning, contentDescription = null, tint = TrainingTint.warningForeground,
                     modifier = Modifier.size(14.dp).padding(top = 1.dp))
                Spacer(Modifier.width(6.dp))
                Text(it, style = Forge.type.caption, color = Forge.colors.text)
            }
        }
        note?.let {
            Row {
                Icon(Icons.Rounded.Info, contentDescription = null, tint = Forge.colors.textTertiary,
                     modifier = Modifier.size(14.dp).padding(top = 1.dp))
                Spacer(Modifier.width(6.dp))
                Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
        }
    }
}

/** The rolling load against the wearer's own baseline, ratios with the usual as a dashed rule (`LoadBaselineTrend`). */
@Composable
private fun LoadBaselineTrend(lane: TrainingLane, ratios: List<Double>, modifier: Modifier = Modifier) {
    val color = lane.color; val bright = lane.bright
    val rule = Forge.colors.textSecondary.copy(alpha = 0.7f)
    val low = minOf(ratios.minOrNull() ?: 1.0, 1.0)
    val high = maxOf(ratios.maxOrNull() ?: 1.0, 1.0)
    val pad = maxOf((high - low) * 0.2, 0.08)
    val lo = maxOf(0.0, low - pad); val hi = high + pad
    Column(modifier, verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(stringResource(R.string.forge_tl_last_8_weeks), style = Forge.type.caption,
                 color = Forge.colors.textSecondary, modifier = Modifier.weight(1f), maxLines = 1)
            Text("⁄ " + stringResource(R.string.forge_tl_your_usual), style = Forge.type.caption,
                 color = Forge.colors.textTertiary, maxLines = 1)
        }
        Canvas(Modifier.fillMaxWidth().height(56.dp)) {
            fun y(v: Double) = (size.height * (1 - (v - lo) / (hi - lo))).toFloat()
            fun x(i: Int) = size.width * i / maxOf(ratios.size - 1, 1)
            drawLine(rule, Offset(0f, y(1.0)), Offset(size.width, y(1.0)), 1.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())))
            val line = smoothPath(ratios.indices.map { Offset(x(it), y(ratios[it])) })
            val area = Path().apply { addPath(line); lineTo(size.width, size.height); lineTo(0f, size.height); close() }
            drawPath(area, Brush.verticalGradient(listOf(color.copy(alpha = 0.26f), Color.Transparent)))
            drawPath(line, color, style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            drawCircle(bright, 3.5.dp.toPx(), Offset(x(ratios.lastIndex), y(ratios.last())))
        }
    }
}

/** A monotone-looking curve through the points (a Catmull-Rom spline, close to Swift Charts' `.monotone`). */
fun smoothPath(points: List<Offset>): Path = Path().apply {
    if (points.isEmpty()) return@apply
    moveTo(points[0].x, points[0].y)
    for (i in 0 until points.size - 1) {
        val p0 = points[maxOf(i - 1, 0)]; val p1 = points[i]; val p2 = points[i + 1]; val p3 = points[minOf(i + 2, points.lastIndex)]
        val c1 = Offset(p1.x + (p2.x - p0.x) / 6f, p1.y + (p2.y - p0.y) / 6f)
        val c2 = Offset(p2.x - (p3.x - p1.x) / 6f, p2.y - (p3.y - p1.y) / 6f)
        cubicTo(c1.x, c1.y, c2.x, c2.y, p2.x, p2.y)
    }
}

/** A card washed in one colour, for the page's statements (`TrainingWashCard`). */
@Composable
fun TrainingWashCard(color: Color, watermark: ImageVector? = null, secondary: Color? = null,
                     content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(ForgeMetrics.cardRadius)
    val fills = if (secondary == null) listOf(color.copy(alpha = 0.28f), color.copy(alpha = 0.06f))
                else listOf(secondary.copy(alpha = 0.26f), color.copy(alpha = 0.26f))
    val surface = Forge.colors.surface
    Box(Modifier.fillMaxWidth().shadow(12.dp, shape, ambientColor = color.copy(alpha = 0.14f), spotColor = color.copy(alpha = 0.14f))
            .clip(shape)
            .drawBehind {
                drawRect(surface)
                drawRect(Brush.linearGradient(fills, start = Offset.Zero, end = Offset(size.width, size.height)))
            }
            .border(BorderStroke(1.dp, color.copy(alpha = 0.35f)), shape)) {
        if (watermark != null) {
            Icon(watermark, contentDescription = null, tint = color.copy(alpha = 0.14f),
                 modifier = Modifier.align(Alignment.TopEnd).padding(top = 0.dp).size(92.dp).rotate(-12f))
        }
        Box(Modifier.padding(ForgeMetrics.cardPadding)) { content() }
    }
}

/** A compact fact that opens its full card (`SummaryTile`). */
@Composable
fun SummaryTile(icon: ImageVector, tint: Color, title: String, headline: String? = null, detail: String? = null,
                modifier: Modifier = Modifier, onClick: () -> Unit, mini: @Composable () -> Unit = {}) {
    val shape = RoundedCornerShape(ForgeMetrics.groupedRadius)
    val surface = Forge.colors.surface
    Column(modifier.heightIn(min = 112.dp).clip(shape)
               .drawBehind {
                   drawRect(surface)
                   drawRect(Brush.linearGradient(listOf(tint.copy(alpha = 0.12f), tint.copy(alpha = 0.03f)),
                                                 start = Offset.Zero, end = Offset(size.width, size.height)))
               }
               .border(BorderStroke(ForgeMetrics.hairline, tint.copy(alpha = 0.18f)), shape)
               .clickable(onClick = onClick).padding(ForgeMetrics.space3),
           verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            StatusBadge(icon, tint, 26.dp)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(title, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.textSecondary,
                 maxLines = 2, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null, tint = Forge.colors.textTertiary,
                 modifier = Modifier.size(16.dp))
        }
        headline?.let { Text(it, style = Forge.type.headline, color = Forge.colors.text, maxLines = 2) }
        detail?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textSecondary) }
        mini()
    }
}

/** One explainer row of the "How it works" list (`ExplainerRows`); the caller opens its page. */
data class ExplainerItem(val id: String, val icon: ImageVector, val title: String, val subtitle: String)

@Composable
fun ExplainerRows(items: List<ExplainerItem>, onOpen: (ExplainerItem) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.gap)) {
        Text(stringResource(R.string.forge_tl_how_it_works), style = Forge.type.title2, color = Forge.sceneInk.text,
             modifier = Modifier.padding(horizontal = ForgeMetrics.space1))
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
            items.forEachIndexed { i, item ->
                if (i > 0) androidx.compose.material3.HorizontalDivider(color = Forge.colors.border.copy(alpha = 0.5f),
                    thickness = ForgeMetrics.hairline, modifier = Modifier.padding(start = 56.dp))
                Row(Modifier.fillMaxWidth().clickable { onOpen(item) }.padding(ForgeMetrics.space3),
                    verticalAlignment = Alignment.CenterVertically) {
                    StatusBadge(item.icon, TrainingTint.cyan, 32.dp)
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(item.title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                        Text(item.subtitle, style = Forge.type.caption, color = Forge.colors.textSecondary, maxLines = 2,
                             overflow = TextOverflow.Ellipsis)
                    }
                    Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = null,
                         tint = Forge.colors.textTertiary, modifier = Modifier.size(16.dp))
                }
            }
        }
    }
}

/** A section heading with small caps over a title (`SectionHeader(_:overline:)`). */
@Composable
fun OverlineHeader(title: String, overline: String) {
    Column(Modifier.padding(horizontal = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(overline.uppercase(), style = Forge.type.overline, color = Forge.sceneInk.secondary)
        Text(title, style = Forge.type.title2, color = Forge.sceneInk.text)
    }
}

// MARK: - Small instruments

/** One pill per recent night, strained ones first (`NightsMeter`). */
@Composable
fun NightsMeter(strained: Int, read: Int, total: Int) {
    val warning = TrainingTint.warning; val positive = TrainingTint.positive; val inset = Forge.colors.inset
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        for (i in 0 until maxOf(total, 1)) {
            Box(Modifier.weight(1f).height(7.dp).background(
                when { i < strained -> warning; i < read -> positive; else -> inset }, CircleShape))
        }
    }
}

/** A small ring filled to a share, the lane's glyph inside (`CoverageRing`). */
@Composable
fun CoverageRing(fraction: Double, color: Color, icon: ImageVector) {
    val inset = Forge.colors.inset
    Box(Modifier.size(36.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(36.dp)) {
            val stroke = 4.dp.toPx()
            val inner = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(stroke / 2, stroke / 2)
            drawArc(inset, 0f, 360f, false, topLeft, inner, style = Stroke(stroke))
            drawArc(color, -90f, (360 * fraction.coerceIn(0.0, 1.0)).toFloat(), false, topLeft, inner,
                    style = Stroke(stroke, cap = StrokeCap.Round))
        }
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(14.dp))
    }
}

/** Eight weeks, one cell per week and lane, each in the band it had at the time (`StatusHistoryStrip`). */
@Composable
fun StatusHistoryStrip(weeks: List<Triple<String, String?, String?>>) {
    val ink = TrainingTint.onDark
    @Composable fun row(icon: ImageVector, pick: (Triple<String, String?, String?>) -> String?) {
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = Forge.colors.textSecondary, modifier = Modifier.width(20.dp).size(14.dp))
            weeks.forEachIndexed { i, week ->
                val band = pick(week)
                val current = i == weeks.lastIndex
                val shape = RoundedCornerShape(7.dp)
                Box(Modifier.weight(1f).height(26.dp)
                        .then(if (current) Modifier.border(BorderStroke(1.5.dp, Forge.colors.text.copy(alpha = 0.7f)),
                                                           RoundedCornerShape(9.dp)).padding(2.5.dp) else Modifier)
                        .background(if (band != null) bandColor(band) else Forge.colors.inset, shape)
                        .background(if (band != null) Brush.verticalGradient(0f to ink.copy(alpha = 0.3f), 0.5f to Color.Transparent)
                                    else Brush.verticalGradient(listOf(Color.Transparent, Color.Transparent)), shape),
                    contentAlignment = Alignment.Center) {
                    if (band != null) Icon(bandIcon(band), contentDescription = null, tint = ink, modifier = Modifier.size(11.dp))
                }
            }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        row(Icons.Rounded.FitnessCenter) { it.second }
        row(Icons.Rounded.Favorite) { it.third }
        Row(Modifier.padding(start = 24.dp)) {
            Text(weeks.firstOrNull()?.first?.let(::shortDate) ?: "", style = Forge.type.caption,
                 color = Forge.colors.textTertiary, modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_tl_this_week), style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
}

/** Rising / unclear / falling lifts as a donut, the count of lifts in the middle (`LiftDirectionDonut`). */
@Composable
fun LiftDirectionDonut(rising: Int, unclear: Int, falling: Int) {
    val parts = listOf(rising to TrainingTint.positive, unclear to Forge.colors.textTertiary, falling to TrainingTint.critical)
        .filter { it.first > 0 }
    val total = maxOf(rising + unclear + falling, 1)
    Box(Modifier.size(116.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(116.dp)) {
            val stroke = size.width * 0.17f
            val inner = Size(size.width - stroke, size.height - stroke)
            val topLeft = Offset(stroke / 2, stroke / 2)
            val gap = if (parts.size > 1) 2f else 0f
            var start = -90f
            for ((count, color) in parts) {
                val sweep = 360f * count / total
                drawArc(color, start + gap / 2, sweep - gap, false, topLeft, inner, style = Stroke(stroke))
                start += sweep
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(NumberFormat.getIntegerInstance(Locale.getDefault()).format(rising + unclear + falling),
                 style = numberStyle(Forge.type.heroNumber, 28, FontWeight.Bold),
                 color = Forge.colors.text)
            Text(stringResource(R.string.forge_tl_lifts), style = Forge.type.caption, color = Forge.colors.textSecondary)
        }
    }
}

/** Eight weeks of VO2max with the first reading as a dashed baseline and the latest lit (`VO2maxSparkline`). */
@Composable
fun VO2maxSparkline(values: List<Double>, color: Color) {
    val rule = Forge.colors.textTertiary.copy(alpha = 0.7f)
    val rim = Forge.colors.surface
    Canvas(Modifier.fillMaxWidth().height(110.dp)) {
        if (values.size < 2) return@Canvas
        val low = values.min() - 1.5; val high = values.max() + 1.5
        val startPad = 6.dp.toPx(); val endPad = 14.dp.toPx()
        fun x(i: Int) = startPad + (size.width - startPad - endPad) * i / (values.size - 1)
        fun y(v: Double) = (size.height * (1 - (v - low) / (high - low))).toFloat()
        drawLine(rule, Offset(0f, y(values.first())), Offset(size.width, y(values.first())), 1.dp.toPx(),
                 pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 4.dp.toPx())))
        val line = smoothPath(values.indices.map { Offset(x(it), y(values[it])) })
        val area = Path().apply { addPath(line); lineTo(x(values.lastIndex), size.height); lineTo(x(0), size.height); close() }
        drawPath(area, Brush.verticalGradient(listOf(color.copy(alpha = 0.34f), Color.Transparent)))
        drawPath(line, Brush.horizontalGradient(listOf(color.copy(alpha = 0.5f), color)),
                 style = Stroke(3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        focusDot(Offset(x(values.lastIndex), y(values.last())), color, rim)
    }
}

/** The focused point on a line: the colour with a rim and a soft halo (`FocusDot`). */
fun DrawScope.focusDot(center: Offset, color: Color, rim: Color) {
    drawCircle(color.copy(alpha = 0.25f), 14.dp.toPx(), center)
    drawCircle(rim, 6.dp.toPx(), center)
    drawCircle(color, 6.dp.toPx() - 2.5.dp.toPx(), center)
}

/**
 * Eight weeks of one lane's ratio against its usual, clamped to 0.4–1.8 with the usual dashed (`LoadRatioChart`).
 * The readout names the latest day.
 */
@Composable
fun LoadRatioChart(days: List<String>, strength: List<Double?>, cardio: List<Double?>) {
    var lane by rememberSaveable { mutableIntStateOf(0) }
    val values = if (lane == 0) strength else cardio
    val tint = if (lane == 0) TrainingTint.effort else TrainingTint.cyan
    val samples = days.indices.mapNotNull { i -> values.getOrNull(i)?.let { i to it } }
    val focus = samples.lastOrNull()
    val rule = Forge.colors.textSecondary.copy(alpha = 0.7f)
    val grid = Forge.colors.border.copy(alpha = 0.5f)
    val rim = Forge.colors.surface
    val label = Forge.colors.textTertiary
    Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(stringResource(R.string.forge_tl_load_vs_usual), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Forge.colors.text, modifier = Modifier.weight(1f))
            if (focus != null) {
                Column(horizontalAlignment = Alignment.End) {
                    Text(stringResource(R.string.forge_tl_ratio_usual,
                                        String.format(Locale.getDefault(), "%.2f", focus.second)),
                         style = numberStyle(Forge.type.heroNumber, 17, FontWeight.Bold), color = tint)
                    Text(shortDate(days[focus.first]), style = Forge.type.caption, color = label)
                }
            }
        }
        ForgeSegmented(listOf(stringResource(R.string.forge_th_strength), stringResource(R.string.forge_tl_cardiovascular)),
                       lane, Modifier.fillMaxWidth()) { lane = it }
        Canvas(Modifier.fillMaxWidth().height(190.dp)) {
            val floor = 0.4; val ceiling = 1.8
            val left = 28.dp.toPx(); val endPad = 18.dp.toPx(); val bottom = 18.dp.toPx()
            val plotH = size.height - bottom
            fun y(v: Double) = (plotH * (1 - (v.coerceIn(floor, ceiling) - floor) / (ceiling - floor))).toFloat()
            fun x(i: Int) = left + 4.dp.toPx() + (size.width - left - 4.dp.toPx() - endPad) * i / maxOf(days.size - 1, 1)
            for (mark in listOf(0.5, 1.0, 1.5)) {
                drawLine(grid, Offset(left, y(mark)), Offset(size.width, y(mark)), 1f)
            }
            drawLine(rule, Offset(left, y(1.0)), Offset(size.width, y(1.0)), 1.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 4.dp.toPx())))
            if (samples.size >= 2) {
                val line = smoothPath(samples.map { Offset(x(it.first), y(it.second)) })
                val area = Path().apply {
                    addPath(line); lineTo(x(samples.last().first), y(floor)); lineTo(x(samples.first().first), y(floor)); close()
                }
                drawPath(area, Brush.verticalGradient(listOf(tint.copy(alpha = 0.26f), Color.Transparent), endY = plotH))
                drawPath(line, tint, style = Stroke(3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            focus?.let { focusDot(Offset(x(it.first), y(it.second)), tint, rim) }
            val paint = android.graphics.Paint().apply {
                color = android.graphics.Color.argb((label.alpha * 255).toInt(), (label.red * 255).toInt(),
                                                    (label.green * 255).toInt(), (label.blue * 255).toInt())
                textSize = 11.sp.toPx(); isAntiAlias = true
            }
            for (mark in listOf(0.5, 1.0, 1.5)) {
                drawContext.canvas.nativeCanvas.drawText(String.format(Locale.getDefault(), "%.1f", mark), 0f,
                                                         y(mark) + 4.dp.toPx(), paint)
            }
            for (i in days.indices step 14) {
                drawContext.canvas.nativeCanvas.drawText(shortDate(days[i]), x(i) - 12.dp.toPx(), size.height - 2.dp.toPx(), paint)
            }
        }
    }
}
