package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.rounded.KeyboardArrowRight
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Hotel
import androidx.compose.material.icons.rounded.FitnessCenter
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.automirrored.rounded.DirectionsWalk
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.background
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreEnergyDetail
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Forge parity 2026-11: the Energy page as iOS's `ForgeEnergyView`. One question first, "how much have
 * I burned, against a usual day?", answered by one ring: resting and active energy as two arcs, a usual day as the
 * full circle. Under it what was eaten and the balance, where the energy went, the day's curve against other days,
 * the last 30 days as bars a tap selects, and where the figures come from. The shared core reads and prices every
 * figure (`energy.detail`, a usual day from `EnergyUsualDay`); this page only draws them.
 */
@Composable
internal fun ForgeEnergyDetailPage(onBack: () -> Unit) {
    val context = LocalContext.current
    var day by remember { mutableStateOf<String?>(null) }
    var comparison by remember { mutableStateOf("sevenDay") }
    var detail by remember { mutableStateOf<CoreEnergyDetail.Detail?>(null) }
    var loaded by remember { mutableStateOf(false) }
    var series by remember { mutableStateOf("burned") }
    var quality by remember { mutableStateOf(false) }
    LaunchedEffect(day, comparison) {
        detail = withContext(Dispatchers.IO) {
            CoreRead.open(context); CoreEnergyDetail.read(context, day, comparison, dismissedTrainingWorkouts(context))
        }
        loaded = true
    }
    if (quality) {
        androidx.activity.compose.BackHandler { quality = false }
        detail?.selected?.let { QualityPage(it) { quality = false } }
        return
    }
    SettingsColumn {
        // The explaining picture in the title row, as iOS's Energy page carries it in its toolbar.
        PageTitle(stringResource(R.string.forge_en_title), onBack) {
            ExplainerInfoButton(R.string.forge_ex_energy_title, R.string.forge_ex_energy_text) { ExplainerEnergyBars() }
        }
        val d = detail
        if (d == null) {
            if (!loaded) Text(stringResource(R.string.forge_goals_loading), style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        val isToday = d.day == d.today
        DayStepper(d, onDay = { day = it })
        val s = d.selected
        val eaten = d.intake[d.day]
        if (s != null && (s.total != null || eaten != null)) {
            Hero(s, d, eaten, isToday)
            Parts(s, d)
            RateCard(d, isToday, comparison) { comparison = it }
        } else {
            EmptyCard(isToday)
        }
        if (d.summaries.isNotEmpty()) History(d, series, onSeries = { series = it }, onDay = { day = it })
        if (s != null) QualityRow(s) { quality = true }
    }
}

private fun kcalText(v: Double): String = NumberFormat.getIntegerInstance(Locale.getDefault()).format(v.roundToInt())

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun DayStepper(d: CoreEnergyDetail.Detail, onDay: (String) -> Unit) {
    val colors = Forge.colors
    val date = LocalDate.parse(d.day)
    val today = LocalDate.parse(d.today)
    val oldest = today.minusDays(29)
    val label = when (date) {
        today -> stringResource(R.string.forge_en_today)
        today.minusDays(1) -> stringResource(R.string.forge_en_yesterday)
        else -> date.format(DateTimeFormatter.ofPattern("EEEE, d MMM", Locale.getDefault()))
    }
    var picking by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        IconButton(enabled = date.isAfter(oldest), onClick = { onDay(date.minusDays(1).toString()) }) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowLeft, contentDescription = stringResource(R.string.forge_en_prev),
                 tint = if (date.isAfter(oldest)) colors.text else colors.textTertiary)
        }
        Spacer(Modifier.weight(1f))
        val spoken = stringResource(R.string.forge_join_dot, stringResource(R.string.forge_en_choose_date), label)
        Row(Modifier.clip(CircleShape).background(colors.surface).clickable(role = Role.Button) { picking = true }
                .semantics { contentDescription = spoken }.padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(label, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
            Icon(Icons.Rounded.CalendarMonth, null, tint = colors.accent, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.weight(1f))
        IconButton(enabled = date.isBefore(today), onClick = { onDay(date.plusDays(1).toString()) }) {
            Icon(Icons.AutoMirrored.Rounded.KeyboardArrowRight, contentDescription = stringResource(R.string.forge_en_next),
                 tint = if (date.isBefore(today)) colors.text else colors.textTertiary)
        }
    }
    if (picking) {
        val zone = java.time.ZoneOffset.UTC
        val state = androidx.compose.material3.rememberDatePickerState(
            initialSelectedDateMillis = date.atStartOfDay(zone).toInstant().toEpochMilli(),
            selectableDates = object : androidx.compose.material3.SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val dd = java.time.Instant.ofEpochMilli(utcTimeMillis).atZone(zone).toLocalDate()
                    return !dd.isBefore(oldest) && !dd.isAfter(today)
                }
            })
        androidx.compose.material3.DatePickerDialog(onDismissRequest = { picking = false }, confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                state.selectedDateMillis?.let { onDay(java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDate().toString()) }
                picking = false
            }) { Text(stringResource(R.string.forge_g_done)) }
        }) { androidx.compose.material3.DatePicker(state) }
    }
}

/** The ring alone and centred, the line under it, then the day's figures, the balance and the forecast. */
@Composable
private fun Hero(s: CoreEnergyDetail.Summary, d: CoreEnergyDetail.Detail, eaten: Double?, isToday: Boolean) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            EnergyRing(s.basal, s.active, s.total, d.usualTotal, Modifier.padding(top = 4.dp).size(200.dp))
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (s.total != null) Text(stringResource(if (isToday) R.string.forge_en_burned_so_far else R.string.forge_en_burned),
                                          style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                usualLine(s.total, d.usualTotal)?.let {
                    Text(it, style = Forge.type.caption, color = colors.textSecondary, textAlign = TextAlign.Center)
                }
            }
            if (s.total != null || eaten != null) {
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                    Figure(ForgeTokens.StrandPalette.forgeEnergyResting.resolve(), stringResource(R.string.forge_en_resting), s.basal, Modifier.weight(1f))
                    Figure(ForgeTokens.StrandPalette.forgeEnergyActive.resolve(), stringResource(R.string.forge_en_active), s.active, Modifier.weight(1f))
                    if (eaten != null) Figure(colors.charge, stringResource(R.string.forge_en_eaten), eaten, Modifier.weight(1f))
                }
            }
            if (eaten != null && s.total != null) Balance(eaten, s.total, isToday)
            if (isToday && s.projectedLow != null && s.projectedHigh != null) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Rounded.Bedtime, null, tint = colors.textSecondary, modifier = Modifier.size(14.dp))
                    Text(stringResource(R.string.forge_en_tonight, kcalText(s.projectedLow), kcalText(s.projectedHigh)),
                         style = Forge.type.caption, color = colors.textSecondary)
                }
            }
            qualityNote(s, isToday)?.let {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Rounded.Info, null, tint = colors.textSecondary, modifier = Modifier.size(14.dp).padding(top = 1.dp))
                    Text(it, style = Forge.type.caption, color = colors.textSecondary)
                }
            }
        }
    }
}

/** The day against a usual one, in words, as iOS's `usualLine`. */
@Composable
private fun usualLine(total: Double?, usual: Double?): String? {
    if (usual == null || total == null || total <= 0) return null
    val gap = total - usual
    return when {
        kotlin.math.abs(gap) < 50 -> stringResource(R.string.forge_en_usual)
        gap < 0 -> stringResource(R.string.forge_en_short, kcalText(-gap))
        else -> stringResource(R.string.forge_en_past, kcalText(gap))
    }
}

/** What the figure rests on, as iOS's `EnergyHeroCard.qualityNote`; none for a fully measured day. */
@Composable
private fun qualityNote(s: CoreEnergyDetail.Summary, isToday: Boolean): String? = when (s.source) {
    "profileOnly" -> stringResource(if (isToday) R.string.forge_en_q_profile_today else R.string.forge_en_q_profile_day)
    "stepsEstimate" -> stringResource(if (isToday) R.string.forge_en_q_steps_today else R.string.forge_en_q_steps_day)
    "loggedActivity" -> stringResource(if (isToday) R.string.forge_en_q_logged_today else R.string.forge_en_q_logged_day)
    else -> when (s.confidence) {
        "building" -> stringResource(R.string.forge_en_q_partly)
        "calibrating" -> stringResource(if (isToday) R.string.forge_en_q_mostly_today else R.string.forge_en_q_mostly_day)
        else -> null
    }
}

@Composable
private fun Figure(color: Color, title: String, value: Double?, modifier: Modifier) {
    val colors = Forge.colors
    Column(modifier.clip(RoundedCornerShape(10.dp)).background(colors.canvas).padding(vertical = 12.dp),
           horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(value?.let(::kcalText) ?: "–", style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = colors.text, maxLines = 1)
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(color))
            Text(title, style = Forge.type.caption, color = colors.textSecondary, maxLines = 1)
        }
    }
}

/** iOS's `ForgeEnergyRing`: resting then active on a circle a usual day fills, the total in the middle. */
@Composable
private fun EnergyRing(resting: Double?, active: Double?, total: Double?, usual: Double?, modifier: Modifier) {
    val colors = Forge.colors
    val rest = ForgeTokens.StrandPalette.forgeEnergyResting.resolve()
    val act = ForgeTokens.StrandPalette.forgeEnergyActive.resolve()
    val track = act.copy(alpha = 0.16f)
    val scale = maxOf(usual ?: 0.0, total ?: 0.0, 1.0)
    val split = resting != null && active != null && resting + active > 0
    val restFraction = if (total == null || total <= 0) 0.0 else if (split) resting!! / scale else total / scale
    val activeFraction = if (split) active!! / scale else 0.0
    val drawn = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(restFraction, activeFraction) { drawn.snapTo(0f); drawn.animateTo(1f, androidx.compose.animation.core.tween(900)) }
    val noData = stringResource(R.string.forge_no_data)
    Box(modifier.semantics(mergeDescendants = true) {}, contentAlignment = Alignment.Center) {
        Canvas(Modifier.matchParentSize()) {
            val w = 16.dp.toPx()
            val inset = w / 2
            val arcSize = Size(size.width - w, size.height - w)
            drawArc(track, 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(w))
            fun arc(from: Double, to: Double, c: Color) {
                val f = (minOf(from, 1.0) * drawn.value).toFloat(); val t = (minOf(to, 1.0) * drawn.value).toFloat()
                if (t > f) drawArc(c, -90f + 360f * f, 360f * (t - f), false, Offset(inset, inset), arcSize, style = Stroke(w, cap = StrokeCap.Round))
            }
            arc(0.0, restFraction, rest)
            arc(restFraction, restFraction + activeFraction, act)
        }
        if (total == null) {
            Text(noData, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary,
                 textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 22.dp))
        } else {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(kcalText(total), style = Forge.type.title1.copy(fontSize = 36.sp, fontWeight = FontWeight.Bold), color = colors.text, maxLines = 1)
                Text("kcal", style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary)
            }
        }
    }
}

/** iOS's `ForgeEnergyBalance`: eaten against burned as one bar either side of zero. */
@Composable
private fun Balance(eaten: Double, burned: Double, isToday: Boolean) {
    val colors = Forge.colors
    val balance = eaten - burned
    val magnitude = (kotlin.math.abs(balance) / maxOf(burned, 1.0)).coerceAtMost(1.0).toFloat()
    val tint = if (balance > 0) colors.effort else colors.charge
    val mid = colors.text.copy(alpha = 0.6f)
    val ground = colors.canvas
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.Bottom) {
            Text(stringResource(if (isToday) R.string.forge_en_balance_so_far else R.string.forge_en_balance), style = Forge.type.caption,
                 color = colors.textSecondary, modifier = Modifier.weight(1f))
            Text((if (balance > 0) "+" else if (balance < 0) "−" else "") + kcalText(kotlin.math.abs(balance)) + " kcal",
                 style = Forge.type.headline, color = colors.text)
        }
        Canvas(Modifier.fillMaxWidth().height(10.dp).clip(CircleShape)) {
            val half = size.width / 2
            drawRect(ground)
            val len = half * magnitude
            drawRect(tint, Offset(if (balance > 0) half else half - len, 0f), Size(len, size.height))
            drawRect(mid, Offset(half - 1.dp.toPx(), 0f), Size(2.dp.toPx(), size.height))
        }
        Row {
            Text(stringResource(R.string.forge_en_deficit), style = Forge.type.caption.copy(fontSize = 11.sp), color = colors.textTertiary,
                 modifier = Modifier.weight(1f))
            Text(stringResource(R.string.forge_en_surplus), style = Forge.type.caption.copy(fontSize = 11.sp), color = colors.textTertiary)
        }
    }
}

/** "Where it comes from": basal burn, daily movement and training with their share, on a day with a minute grid. */
@Composable
private fun Parts(s: CoreEnergyDetail.Summary, d: CoreEnergyDetail.Detail) {
    val total = s.total ?: return
    val movement = d.movementKcal ?: return
    val training = d.trainingKcal ?: return
    if (total <= 0) return
    EnergySection(stringResource(R.string.forge_en_where))
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = 0.dp) {
        PartRow(Icons.Rounded.Hotel, ForgeTokens.StrandPalette.forgeEnergyResting.resolve(), stringResource(R.string.forge_en_basal),
                s.basal ?: s.bmr24h, s.basal?.let { it / total })
        HubDivider()
        PartRow(Icons.AutoMirrored.Rounded.DirectionsWalk, ForgeTokens.StrandPalette.forgeEnergyMovement.resolve(),
                stringResource(R.string.forge_en_movement), movement, movement / total)
        HubDivider()
        PartRow(Icons.Rounded.FitnessCenter, ForgeTokens.StrandPalette.forgeEnergyTraining.resolve(),
                stringResource(R.string.forge_en_training), training, training / total)
    }
}

@Composable
private fun EnergySection(title: String) {
    Text(title, style = Forge.type.title2.copy(fontWeight = FontWeight.Bold), color = Forge.sceneInk.text,
         modifier = Modifier.padding(top = ForgeMetrics.space2, start = ForgeMetrics.space1))
}

@Composable
private fun PartRow(icon: androidx.compose.ui.graphics.vector.ImageVector, tint: Color, title: String, value: Double?, share: Double?) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().padding(horizontal = ForgeMetrics.space4, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(32.dp).clip(CircleShape).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(title, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text, modifier = Modifier.weight(1f))
                Text(value?.let(::kcalText) ?: "–", style = Forge.type.headline, color = colors.text)
                Text(stringResource(R.string.forge_join_space, "", "kcal"), style = Forge.type.caption, color = colors.textSecondary)
            }
            if (share != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val track = colors.inset
                    Canvas(Modifier.weight(1f).height(6.dp).clip(CircleShape)) {
                        drawRect(track)
                        drawRect(tint, size = Size(size.width * share.coerceIn(0.0, 1.0).toFloat(), size.height))
                    }
                    Text(NumberFormat.getPercentInstance(Locale.getDefault()).format(share.coerceIn(0.0, 1.0)),
                         style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = colors.textSecondary,
                         textAlign = TextAlign.End, modifier = Modifier.width(36.dp))
                }
            }
        }
    }
}

@Composable
private fun EmptyCard(isToday: Boolean) {
    val colors = Forge.colors
    val tint = ForgeTokens.StrandPalette.forgeEnergyActive.resolve()
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(Modifier.size(48.dp).clip(CircleShape).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.LocalFireDepartment, null, tint = tint)
            }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(stringResource(if (isToday) R.string.forge_en_nothing_today else R.string.forge_en_nothing_day),
                     style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                Text(stringResource(R.string.forge_en_appears), style = Forge.type.caption, color = colors.textSecondary)
            }
        }
    }
}

/** The last 30 days as bars of the chosen series; a tap on a bar opens that day. Today stays out. */
@Composable
private fun History(d: CoreEnergyDetail.Detail, series: String, onSeries: (String) -> Unit, onDay: (String) -> Unit) {
    val colors = Forge.colors
    val rest = ForgeTokens.StrandPalette.forgeEnergyResting.resolve()
    val act = ForgeTokens.StrandPalette.forgeEnergyActive.resolve()
    val days = d.summaries.filter { it.day != d.today }.sortedBy { it.day }
    data class Bar(val day: String, val parts: List<Pair<Double, Color>>)
    val bars = days.mapNotNull { s ->
        when (series) {
            "eaten" -> d.intake[s.day]?.let { Bar(s.day, listOf(it to colors.charge)) }
            "balance" -> { val e = d.intake[s.day]; val t = s.total
                if (e == null || t == null) null else (e - t).let { b -> Bar(s.day, listOf(b to if (b > 0) colors.effort else colors.charge)) } }
            else -> { val t = s.total
                if (t == null || t <= 0) null
                else if (s.basal != null && s.active != null && s.basal + s.active > 0) Bar(s.day, listOf(s.basal to rest, s.active to act))
                else Bar(s.day, listOf(t to rest)) }
        }
    }
    EnergySection(stringResource(R.string.forge_en_last30))
    if (d.intake.isNotEmpty()) {
        Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(colors.inset).padding(2.dp)) {
            listOf("burned" to R.string.forge_en_burned, "eaten" to R.string.forge_en_eaten, "balance" to R.string.forge_en_balance).forEach { (key, label) ->
                val on = series == key
                Text(stringResource(label), style = Forge.type.footnote.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal),
                     color = colors.text, textAlign = TextAlign.Center,
                     modifier = Modifier.weight(1f).clip(RoundedCornerShape(7.dp)).background(if (on) colors.surface else Color.Transparent)
                         .clickable(role = Role.Tab) { onSeries(key) }.padding(vertical = 6.dp))
            }
        }
    }
    ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
        if (bars.isEmpty()) {
            Text(stringResource(R.string.forge_en_nothing_logged), style = Forge.type.caption, color = colors.textSecondary,
                 modifier = Modifier.fillMaxWidth().height(120.dp))
            return@ForgeCard
        }
        val usual = d.usualTotal.takeIf { series == "burned" }
        val balance = series == "balance"
        val values = bars.map { b -> b.parts.sumOf { it.first } }
        val low = if (balance) minOf(values.min(), 0.0) else 0.0
        val high = if (balance) maxOf(values.max(), 0.0) else maxOf(values.max(), usual ?: 0.0)
        val pad = if (balance) maxOf(100.0, (high - low) * 0.12) else 0.0
        val lo = low - pad
        val hi = if (balance) high + pad else maxOf(high * 1.12, 100.0)
        val first = LocalDate.parse(d.today).minusDays(29)
        val ruler = colors.textSecondary
        val zero = colors.textTertiary
        val label = stringResource(R.string.forge_en_burned)
        Canvas(Modifier.fillMaxWidth().height(190.dp).semantics { contentDescription = label }
                .pointerInput(bars) {
                    detectTapGestures { pos ->
                        val idx = (pos.x / size.width * 30).toInt().coerceIn(0, 29)
                        val dayKey = first.plusDays(idx.toLong()).toString()
                        if (d.summaries.any { it.day == dayKey }) onDay(dayKey)
                    }
                }) {
            val slot = size.width / 30
            fun y(v: Double) = ((hi - v) / (hi - lo)).toFloat() * size.height
            bars.forEach { b ->
                val idx = java.time.temporal.ChronoUnit.DAYS.between(first, LocalDate.parse(b.day)).toInt()
                if (idx !in 0..29) return@forEach
                val x = slot * idx + slot * 0.15f
                val alpha = if (b.day == d.day || d.day == d.today) 1f else 0.42f
                if (balance) {
                    val (v, c) = b.parts.first()
                    val top = y(maxOf(v, 0.0)); val bottom = y(minOf(v, 0.0))
                    drawRoundRect(c.copy(alpha = alpha), Offset(x, top), Size(slot * 0.7f, bottom - top), CornerRadius(3.dp.toPx()))
                } else {
                    var base = 0.0
                    b.parts.forEach { (v, c) ->
                        val top = y(base + v); val bottom = y(base)
                        drawRoundRect(c.copy(alpha = alpha), Offset(x, top), Size(slot * 0.7f, bottom - top), CornerRadius(3.dp.toPx()))
                        base += v
                    }
                }
            }
            usual?.let { drawLine(ruler, Offset(0f, y(it)), Offset(size.width, y(it)), 1.dp.toPx(),
                                  pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))) }
            if (balance) drawLine(zero, Offset(0f, y(0.0)), Offset(size.width, y(0.0)), 1.dp.toPx())
        }
        Row {
            Text(shortDay(first.toString()), style = Forge.type.caption, color = colors.textTertiary)
            Spacer(Modifier.weight(1f))
            Text(shortDay(LocalDate.parse(d.today).minusDays(1).toString()), style = Forge.type.caption, color = colors.textTertiary)
        }
        if (usual != null) Text(stringResource(R.string.forge_en_usual_day, kcalText(usual)), style = Forge.type.caption,
                                color = colors.textSecondary)
        Text(stringResource(R.string.forge_en_tap_day), style = Forge.type.caption, color = colors.textTertiary)
    }
}

/** "Data quality & calculation", opening where the day's figure comes from. */
@Composable
private fun QualityRow(s: CoreEnergyDetail.Summary, onOpen: () -> Unit) {
    val colors = Forge.colors
    val tint = confidenceColor(s.confidence)
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen), contentPadding = ForgeMetrics.space4) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.size(36.dp).clip(CircleShape).background(tint.copy(alpha = 0.14f)), contentAlignment = Alignment.Center) {
                Icon(Icons.Rounded.VerifiedUser, null, tint = tint, modifier = Modifier.size(18.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.forge_en_quality), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = colors.text)
                Text(s.compactLine ?: s.sourceLabel, style = Forge.type.caption, color = colors.textSecondary, maxLines = 2)
            }
            Icon(Icons.Rounded.ChevronRight, null, tint = colors.textTertiary, modifier = Modifier.size(18.dp))
        }
    }
}

/** Where the day's figure comes from: its source, how much of the day was captured and how sure it is. */
@Composable
private fun QualityPage(s: CoreEnergyDetail.Summary, onBack: () -> Unit) {
    val colors = Forge.colors
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_en_quality), onBack)
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
            Text(s.sourceLabel, style = Forge.type.headline, color = colors.text)
            s.compactLine?.let { Text(it, style = Forge.type.body, color = colors.textSecondary) }
            Text(s.confidenceLabel, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = confidenceColor(s.confidence))
        }
    }
}

@Composable
private fun RateCard(d: CoreEnergyDetail.Detail, isToday: Boolean, comparison: String, onComparison: (String) -> Unit) {
    if (d.points.isEmpty()) {
        val s = d.selected ?: return
        if (s.total == null) return
        ForgeCard(Modifier.fillMaxWidth(), contentPadding = ForgeMetrics.space4) {
            Text(stringResource(R.string.forge_en_no_curve), style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = Forge.colors.text)
            Text(stringResource(R.string.forge_en_no_curve_detail, s.sourceLabel), style = Forge.type.caption,
                 color = Forge.colors.textSecondary)
        }
        return
    }
    SettingsCard(title = stringResource(if (isToday) R.string.forge_ed_rate_today else R.string.forge_ed_rate), blurb = null) {
        Text("kcal/min", style = Forge.type.caption, color = Forge.colors.textTertiary)
        RateChart(d.points, d.bands, d.comparisonPoints)
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            listOf("previousDay" to (if (isToday) R.string.forge_ed_yesterday else R.string.forge_ed_day_before),
                   "sevenDay" to R.string.forge_ed_7d, "thirtyDay" to R.string.forge_ed_30d).forEach { (mode, label) ->
                FilterChip(selected = comparison == mode, onClick = { onComparison(mode) }, label = { Text(stringResource(label)) })
            }
        }
        (d.comparisonUnavailable ?: d.comparisonCaption)?.let {
            Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
    }
}

/** The day's rate as a filled line over 24 hours, sessions as shaded bands, the comparison as a thin line. */
@Composable
private fun RateChart(points: List<CoreEnergyDetail.Point>, bands: List<CoreEnergyDetail.Band>,
                      comparison: List<CoreEnergyDetail.Point>) {
    val energy = ForgeTokens.Color.systemOrange.resolve()
    val reference = Forge.colors.textTertiary
    val bandColor = energy.copy(alpha = 0.14f)
    Canvas(Modifier.fillMaxWidth().height(160.dp)) {
        val day = 86_400.0
        val top = (points + comparison).maxOfOrNull { it.kcalPerMinute }?.coerceAtLeast(1.0) ?: 1.0
        fun x(seconds: Double) = (seconds / day * size.width).toFloat()
        fun y(rate: Double) = (size.height - rate / (top * 1.1) * size.height).toFloat()
        bands.forEach { b -> drawRect(bandColor, Offset(x(b.start), 0f), Size(x(b.end) - x(b.start), size.height)) }
        fun path(p: List<CoreEnergyDetail.Point>) = Path().apply {
            p.forEachIndexed { i, pt ->
                val px = x(pt.start + pt.duration / 2)
                if (i == 0) moveTo(px, y(pt.kcalPerMinute)) else lineTo(px, y(pt.kcalPerMinute))
            }
        }
        val line = path(points)
        val fill = Path().apply {
            addPath(line)
            lineTo(x(points.last().start + points.last().duration / 2), size.height)
            lineTo(x(points.first().start + points.first().duration / 2), size.height)
            close()
        }
        drawPath(fill, energy.copy(alpha = 0.18f))
        drawPath(line, energy, style = Stroke(width = 2.dp.toPx()))
        if (comparison.size >= 2) drawPath(path(comparison), reference, style = Stroke(width = 1.5.dp.toPx()))
    }
}

/** The completed days' totals, fitted to their range rather than anchored at zero, as on iOS. */
@Composable
private fun confidenceColor(confidence: String) = when (confidence) {
    "solid" -> ForgeTokens.Color.systemGreen.resolve()
    "building" -> ForgeTokens.Color.systemOrange.resolve()
    else -> Forge.colors.textTertiary
}

private fun shortDay(day: String): String =
    runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", Locale.getDefault())) }.getOrDefault(day)
