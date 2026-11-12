package com.noop.ui.forge


import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.PhotoCamera
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import com.noop.R
import com.noop.core.CoreBody
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.NumberFormat
import java.util.Locale

/**
 * Fork (DX23876), Android parity 2026-11-12: the Body screen in iOS's new-design order (`BodyView.forge`): today's
 * weight, body fat and waist, the one Measure action, what changed at each site against the scale, body fat with the
 * Navy tape estimate on its own line, every measurement's change since its first reading, the sites, progress photos
 * and the two reminders. The shared core resolves the readings, comparisons and estimate.
 */
@Composable
internal fun ForgeBodyPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var body by remember { mutableStateOf<CoreBody.Snapshot?>(null) }
    var revision by remember { mutableIntStateOf(0) }
    var loaded by remember { mutableStateOf(false) }
    var measuring by remember { mutableStateOf(false) }
    var photos by remember { mutableStateOf(false) }
    // iOS's two pickers: how far "What changed" reaches back, and how much history the comparison chart draws.
    var window by remember { mutableIntStateOf(1) }
    var range by remember { mutableIntStateOf(0) }
    androidx.activity.compose.BackHandler(enabled = photos || measuring) { if (photos) photos = false else measuring = false }
    if (photos) {
        ForgeBodyPhotosPage(onBack = { photos = false })
        return
    }
    LaunchedEffect(revision, window, range) {
        body = withContext(Dispatchers.IO) {
            CoreRead.open(context)
            CoreBody.snapshot(context, days = BODY_RANGES[range], comparisonDays = BODY_WINDOWS[window])
        }
        loaded = true
    }
    fun after(block: suspend () -> Boolean) { scope.launch { if (withContext(Dispatchers.IO) { block() }) revision++ } }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_body_title), onBack)
        val b = body
        if (b == null) {
            Text(stringResource(if (loaded) R.string.forge_body_nothing else R.string.forge_goals_loading),
                 style = Forge.type.body, color = Forge.sceneInk.secondary)
            return@SettingsColumn
        }
        if (measuring) {
            WeightCard(b, onLog = { kg -> after { CoreBody.logWeight(kg) } }, onDelete = { id -> after { CoreBody.deleteWeight(id) } })
            MeasureCard(b, onCancel = { measuring = false }) { values ->
                after { CoreBody.record(context, values).also { if (it) measuring = false } }
            }
            return@SettingsColumn
        }
        BodyTodayCard(b)
        BodyMeasureButton { measuring = true }
        BodyDevelopmentCard(b, window) { window = it }
        BodyFatCard(b)
        BodyComparisonCard(b, range) { range = it }
        SitesCard(b, onMeasure = { measuring = true })
        BodyPhotosRow { photos = true }
        BodyRemindersCard()
    }
}

/** iOS's `ComparisonWindow` (3 weeks, 6 weeks, 3 months) and `HistoryRange` (3 months, 1 year, all). */
private val BODY_WINDOWS = listOf(21, 42, 90)
private val BODY_RANGES = listOf(120, 365, 4_000)

/** Today's weight, body fat and waist, each with the day it was taken. */
@Composable
private fun BodyTodayCard(b: CoreBody.Snapshot) {
    val units = com.noop.ui.UnitPrefs.system(LocalContext.current)
    val waist = b.siteSeries["waist"]?.lastOrNull()
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            TodayFigure(b.weight.lastOrNull()?.let { weightLabel(it.value, units) }, stringResource(R.string.forge_body_weight),
                        b.weight.lastOrNull()?.day)
            TodayFigure(b.bodyFat.lastOrNull()?.let { stringResource(R.string.forge_body_pct, one(it.value)) },
                        stringResource(R.string.forge_body_fat), b.bodyFat.lastOrNull()?.day)
            TodayFigure(waist?.let { stringResource(R.string.forge_body_cm, one(it.value)) }, stringResource(R.string.body_waist), waist?.day)
        }
    }
}

@Composable
private fun RowScope.TodayFigure(value: String?, label: String, day: String?) {
    Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
        Text(value ?: "—", style = Forge.type.title2, color = Forge.colors.text, maxLines = 1)
        Text(label, style = Forge.type.subhead, color = Forge.colors.textSecondary, maxLines = 1)
        Text(day?.let { dayText(it) } ?: " ", style = Forge.type.caption, color = Forge.colors.textTertiary, maxLines = 1)
    }
}

@Composable
private fun BodyMeasureButton(onClick: () -> Unit) {
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).background(colors.accent, CircleShape)
            .clickable(role = Role.Button, onClick = onClick),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = colors.onAccent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_body_measure), style = Forge.type.headline, color = colors.onAccent)
    }
}

/** A card heading with the info button iOS puts beside it. */
@Composable
private fun BodyCardHead(title: String, infoTitle: Int, infoText: Int) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f))
        ExplainerInfoButton(infoTitle, infoText) {}
    }
}

/** What changed at each site, read against the scale, as iOS's `developmentCard`. */
@Composable
private fun BodyDevelopmentCard(b: CoreBody.Snapshot, window: Int, onWindow: (Int) -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            BodyCardHead(stringResource(R.string.body_what_changed), R.string.body_info_dev_title, R.string.body_info_dev)
            ForgeSegmented(listOf(stringResource(R.string.body_3_weeks), stringResource(R.string.body_6_weeks),
                                  stringResource(R.string.body_3_months)), window, Modifier.fillMaxWidth(), onWindow)
            if (b.growingSites > 0 || b.shrinkingSites > 0) {
                val gainLeads = b.growingSites >= b.shrinkingSites
                val lead = if (gainLeads) b.growingSites else b.shrinkingSites
                val other = if (gainLeads) b.shrinkingSites else b.growingSites
                Text(stringResource(if (gainLeads) R.string.body_grew else R.string.body_decreased, lead),
                     style = Forge.type.title1, color = colors.text)
                if (other > 0) Text(stringResource(if (gainLeads) R.string.body_decreased else R.string.body_grew, other),
                                    style = Forge.type.title2, color = colors.textSecondary)
                b.weightChangeKg?.let { Text(weightContext(it, b.lostCm ?: 0.0, b.gainedCm ?: 0.0), style = Forge.type.subhead,
                                             color = colors.textSecondary) }
                Text(stringResource(R.string.body_rows_note), style = Forge.type.caption, color = colors.textTertiary)
            } else {
                Text(stringResource(if (b.comparedSites == 0) R.string.body_no_pairs else R.string.body_no_movement),
                     style = Forge.type.subhead, color = colors.textSecondary)
            }
            if (b.changes.isNotEmpty()) {
                Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                val scale = maxOf(b.changes.maxOf { kotlin.math.abs(it.deltaCm) }, 0.5)
                b.changes.forEach { ChangeRow(it, scale) }
            }
        }
    }
}

/** The tape read against the scale, in whichever direction the wearer is going (iOS `weightContextText`). */
@Composable
private fun weightContext(weightKg: Double, lostCm: Double, gainedCm: Double): String {
    val kg = one(kotlin.math.abs(weightKg))
    val id = when {
        kotlin.math.abs(weightKg) < 0.4 -> when {
            lostCm > 0 && gainedCm > 0 -> R.string.body_ctx_0
            lostCm > 0 -> R.string.body_ctx_1
            else -> R.string.body_ctx_2
        }
        weightKg > 0 -> when {
            gainedCm > 0 && lostCm == 0.0 -> R.string.body_ctx_3
            lostCm > 0 && gainedCm > 0 -> R.string.body_ctx_4
            else -> R.string.body_ctx_5
        }
        lostCm > 0 && gainedCm == 0.0 -> R.string.body_ctx_6
        gainedCm > 0 -> R.string.body_ctx_7
        else -> R.string.body_ctx_8
    }
    return stringResource(id, kg)
}

/** One site with a bar diverging from a centre line; direction lives in the geometry, never in a colour. */
@Composable
private fun ChangeRow(c: CoreBody.Change, scale: Double) {
    val colors = Forge.colors
    val ink = if (c.exceedsTypicalStep) colors.text else colors.textTertiary
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp).semantics(mergeDescendants = true) {},
           verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(c.label, style = Forge.type.subhead, color = ink, modifier = Modifier.weight(1f))
            Text("${one(c.fromValue)} → ${one(c.toValue)} cm", style = Forge.type.caption, color = colors.textTertiary)
            Text(signed(c.deltaCm), style = Forge.type.subhead, color = ink, textAlign = TextAlign.End,
                 modifier = Modifier.width(46.dp))
        }
        val tint = if (c.exceedsTypicalStep) colors.accent else colors.textTertiary.copy(alpha = 0.5f)
        val track = colors.inset
        androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(6.dp)) {
            val mid = size.width / 2
            drawRoundRect(track, cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2))
            val w = (kotlin.math.abs(c.deltaCm) / scale).toFloat().coerceIn(0f, 1f) * mid
            val x = if (c.deltaCm >= 0) mid else mid - w
            drawRoundRect(tint, topLeft = androidx.compose.ui.geometry.Offset(x, 0f),
                          size = androidx.compose.ui.geometry.Size(maxOf(w, 2f), size.height),
                          cornerRadius = androidx.compose.ui.geometry.CornerRadius(size.height / 2))
            drawRect(colors.divider, topLeft = androidx.compose.ui.geometry.Offset(mid - 0.5f, -2f),
                     size = androidx.compose.ui.geometry.Size(1f, size.height + 4f))
        }
    }
}

@Composable
private fun WeightCard(b: CoreBody.Snapshot, onLog: (Double) -> Unit, onDelete: (String) -> Unit) {
    var text by remember { mutableStateOf("") }
    // Settings › Units: weights show and are typed in pounds for an imperial wearer; the core stores kilograms.
    val units = com.noop.ui.UnitPrefs.system(androidx.compose.ui.platform.LocalContext.current)
    SettingsCard(title = stringResource(R.string.forge_body_weight), blurb = null) {
        b.weight.lastOrNull()?.let {
            Text(weightLabel(it.value, units), style = Forge.type.title2, color = Forge.colors.text)
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(value = text, onValueChange = { v -> text = v.filter { it.isDigit() || it == '.' || it == ',' }.take(6) },
                              singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                              suffix = { Text(com.noop.ui.UnitFormatter.massUnit(units)) }, modifier = Modifier.weight(1f),
                              colors = forgeFieldColors())
            Spacer(Modifier.width(ForgeMetrics.space2))
            val kg = weightForStore(text, units)
            TextButton(enabled = kg != null && kg > 0, onClick = { kg?.let(onLog); text = "" }) {
                Text(stringResource(R.string.forge_body_log_weight))
            }
        }
        if (b.weighIns.isNotEmpty()) {
            Text(stringResource(R.string.forge_body_weigh_ins), style = Forge.type.overline, color = Forge.colors.textSecondary)
            b.weighIns.take(5).forEach { w ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(w.day, style = Forge.type.body, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
                    Text(weightLabel(w.value, units), style = Forge.type.body, color = Forge.colors.text)
                    w.id?.let { id -> TextButton(onClick = { onDelete(id) }) { Text(stringResource(R.string.forge_body_delete)) } }
                }
            }
        }
    }
}

/** Body fat with the Navy tape estimate on its own line and each measured source apart, as iOS's `compositionCard`. */
@Composable
private fun BodyFatCard(b: CoreBody.Snapshot) {
    val colors = Forge.colors
    val context = LocalContext.current
    val equation = remember { com.noop.ui.ProfileStore.from(context).sex.lowercase().takeIf { it == "male" || it == "female" } }
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            BodyCardHead(stringResource(R.string.forge_body_fat), R.string.body_info_navy_title, R.string.body_info_navy)
            when {
                b.navyEstimate != null -> {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(one(b.navyEstimate), style = Forge.type.title1, color = colors.text)
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.forge_body_pct_estimated), style = Forge.type.subhead, color = colors.textSecondary,
                             modifier = Modifier.padding(bottom = 4.dp))
                    }
                    Text(stringResource(R.string.body_navy_note, b.navyErrorBand.toInt()), style = Forge.type.caption, color = colors.textSecondary)
                }
                equation == null -> Text(stringResource(R.string.body_navy_choose), style = Forge.type.subhead, color = colors.textSecondary)
                b.navyMissing.isEmpty() -> Text(stringResource(R.string.body_navy_implausible), style = Forge.type.subhead,
                                                color = colors.textSecondary)
                else -> {
                    Text(stringResource(R.string.body_navy_measure), style = Forge.type.subhead, color = colors.textSecondary)
                    Text(b.navyMissing.joinToString(" · "), style = Forge.type.subhead, color = colors.text)
                }
            }
            val bySource = b.bodyFat.groupBy { it.source }.toSortedMap()
            if (bySource.isNotEmpty()) {
                Box(Modifier.fillMaxWidth().height(ForgeMetrics.hairline).background(colors.divider))
                bySource.forEach { (source, points) ->
                    val newest = points.last()
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(sourceLabel(source), style = Forge.type.subhead, color = colors.textSecondary, modifier = Modifier.weight(1f))
                        Text(stringResource(R.string.forge_body_pct, one(newest.value)), style = Forge.type.subhead, color = colors.text)
                        Spacer(Modifier.width(ForgeMetrics.space2))
                        Text(dayText(newest.day), style = Forge.type.caption, color = colors.textTertiary)
                    }
                }
            }
        }
    }
}

@Composable
private fun sourceLabel(source: String): String = when (source) {
    "dexa" -> stringResource(R.string.body_src_dexa)
    "caliper" -> stringResource(R.string.body_src_caliper)
    "bia" -> stringResource(R.string.body_src_bia)
    "inbody" -> stringResource(R.string.body_src_inbody)
    "navy" -> stringResource(R.string.body_src_navy)
    "profile" -> stringResource(R.string.body_src_profile)
    else -> if (source.contains("health", ignoreCase = true)) "Health Connect" else stringResource(R.string.body_src_entered)
}

/** Weight, waist and body fat as percent change from each one's first reading, on one axis (iOS `comparisonCard`). */
@Composable
private fun BodyComparisonCard(b: CoreBody.Snapshot, range: Int, onRange: (Int) -> Unit) {
    val colors = Forge.colors
    val series = listOf(
        Triple(stringResource(R.string.forge_body_weight), b.weight, ForgeTokens.Color.systemOrange.resolve()),
        Triple(stringResource(R.string.body_waist), b.siteSeries["waist"].orEmpty(), ForgeTokens.Color.systemPurple.resolve()),
        Triple(stringResource(R.string.forge_body_fat), b.bodyFat, ForgeTokens.Color.systemCyan.resolve()),
    ).filter { it.second.size >= 2 && it.second.first().value > 0 }
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            BodyCardHead(stringResource(R.string.body_change_since), R.string.body_info_cmp_title, R.string.body_info_cmp)
            ForgeSegmented(listOf(stringResource(R.string.body_3_months), stringResource(R.string.body_1_year),
                                  stringResource(R.string.body_all)), range, Modifier.fillMaxWidth(), onRange)
            if (series.isEmpty()) {
                Text(stringResource(R.string.body_chart_empty), style = Forge.type.subhead, color = colors.textSecondary)
                return@Column
            }
            val lines = series.map { (_, points, tint) ->
                val base = points.first().value
                tint to points.mapNotNull { r ->
                    runCatching { java.time.LocalDate.parse(r.day).toEpochDay() }.getOrNull()?.let { it to (r.value - base) / base * 100 }
                }
            }
            val days = lines.flatMap { l -> l.second.map { it.first } }
            val values = lines.flatMap { l -> l.second.map { it.second } }
            val lo = minOf(values.minOrNull() ?: -1.0, -1.0); val hi = maxOf(values.maxOrNull() ?: 1.0, 1.0)
            val first = days.minOrNull() ?: 0L; val last = maxOf(days.maxOrNull() ?: 1L, first + 1)
            val grid = colors.divider
            androidx.compose.foundation.Canvas(Modifier.fillMaxWidth().height(180.dp)) {
                fun x(d: Long) = (d - first).toFloat() / (last - first) * size.width
                fun y(v: Double) = ((hi - v) / (hi - lo)).toFloat() * size.height
                drawLine(grid, androidx.compose.ui.geometry.Offset(0f, y(0.0)), androidx.compose.ui.geometry.Offset(size.width, y(0.0)),
                         strokeWidth = 1.dp.toPx())
                lines.forEach { (tint, pts) ->
                    val path = androidx.compose.ui.graphics.Path()
                    pts.forEachIndexed { i, (d, v) -> if (i == 0) path.moveTo(x(d), y(v)) else path.lineTo(x(d), y(v)) }
                    drawPath(path, tint, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx(),
                             cap = androidx.compose.ui.graphics.StrokeCap.Round, join = androidx.compose.ui.graphics.StrokeJoin.Round))
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                series.forEach { (label, _, tint) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(7.dp).background(tint, CircleShape))
                        Spacer(Modifier.width(4.dp))
                        Text(label, style = Forge.type.caption, color = colors.textTertiary)
                    }
                }
            }
            Text(stringResource(R.string.body_chart_note), style = Forge.type.caption, color = colors.textSecondary)
        }
    }
}

/** Every measured site with its sparkline and value; the date shows only where it differs from the latest session. */
@Composable
private fun SitesCard(b: CoreBody.Snapshot, onMeasure: () -> Unit) {
    val colors = Forge.colors
    val newest = b.measured.mapNotNull { b.siteSeries[it.key]?.lastOrNull()?.day }.maxOrNull()
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(stringResource(R.string.body_measurements), style = Forge.type.headline, color = colors.text, modifier = Modifier.weight(1f))
                Text(newest?.let { stringResource(R.string.body_last_measured, dayText(it)) } ?: stringResource(R.string.body_all_sites),
                     style = Forge.type.footnote, color = colors.textSecondary)
            }
            if (b.measured.isEmpty()) {
                Text(stringResource(R.string.body_no_tape), style = Forge.type.subhead, color = colors.textSecondary,
                     modifier = Modifier.clickable(role = Role.Button, onClick = onMeasure))
            }
            b.measured.forEach { site ->
                val points = b.siteSeries[site.key].orEmpty()
                val reading = points.lastOrNull() ?: return@forEach
                Row(Modifier.fillMaxWidth().semantics(mergeDescendants = true) {}, verticalAlignment = Alignment.CenterVertically) {
                    Text(site.label, style = Forge.type.subhead, color = colors.text, modifier = Modifier.weight(1f))
                    if (points.size >= 2) {
                        val line = ForgeTokens.Color.systemCyan.resolve()
                        val vals = points.map { it.value }
                        val lo = vals.min(); val hi = maxOf(vals.max(), lo + 0.1)
                        androidx.compose.foundation.Canvas(Modifier.width(46.dp).height(18.dp)) {
                            val path = androidx.compose.ui.graphics.Path()
                            vals.forEachIndexed { i, v ->
                                val px = i.toFloat() / (vals.size - 1) * size.width
                                val py = ((hi - v) / (hi - lo)).toFloat() * size.height
                                if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
                            }
                            drawPath(path, line, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5.dp.toPx()))
                        }
                        Spacer(Modifier.width(ForgeMetrics.space2))
                    }
                    Text(stringResource(R.string.forge_body_cm, one(reading.value)), style = Forge.type.subhead, color = colors.text)
                    Text(if (reading.day == newest) "" else dayText(reading.day), style = Forge.type.caption,
                         color = ForgeTokens.Color.systemOrange.resolve(), textAlign = TextAlign.End, modifier = Modifier.width(52.dp))
                }
            }
        }
    }
}

@Composable
private fun BodyPhotosRow(onOpen: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.PhotoCamera, contentDescription = null, tint = ForgeTokens.Color.systemPurple.resolve())
            Spacer(Modifier.width(ForgeMetrics.space3))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.body_photos), style = Forge.type.subhead, color = colors.text)
                Text(stringResource(R.string.body_photos_note), style = Forge.type.caption, color = colors.textSecondary)
            }
            Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = colors.textTertiary)
        }
    }
}

/** The weekly tape reminder and the daily weigh-in, as iOS's `remindersCard`; a refusal is said, not hidden. */
@Composable
private fun BodyRemindersCard() {
    val colors = Forge.colors
    val context = LocalContext.current
    var weekly by remember { mutableStateOf(com.noop.notif.BodyMeasurementReminder.weeklyEnabled(context)) }
    var daily by remember { mutableStateOf(com.noop.notif.BodyMeasurementReminder.dailyEnabled(context)) }
    var denied by remember { mutableStateOf(false) }
    fun set(on: Boolean, isDaily: Boolean) {
        val ok = com.noop.notif.BodyMeasurementReminder.setEnabled(context, on, isDaily)
        denied = !ok
        weekly = com.noop.notif.BodyMeasurementReminder.weeklyEnabled(context)
        daily = com.noop.notif.BodyMeasurementReminder.dailyEnabled(context)
    }
    ForgeCard(Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            Text(stringResource(R.string.body_reminders), style = Forge.type.headline, color = colors.text)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.body_weekly), style = Forge.type.body, color = colors.text)
                    Text(stringResource(R.string.body_weekly_note), style = Forge.type.caption, color = colors.textSecondary)
                }
                Switch(checked = weekly, onCheckedChange = { set(it, false) }, colors = forgeSwitchColors())
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.body_daily), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                Switch(checked = daily, onCheckedChange = { set(it, true) }, colors = forgeSwitchColors())
            }
            if (denied) Text(stringResource(R.string.body_reminder_denied), style = Forge.type.caption,
                             color = ForgeTokens.Color.systemOrange.resolve())
        }
    }
}

@Composable
private fun MeasureCard(b: CoreBody.Snapshot, onCancel: () -> Unit, onSave: (Map<String, Double>) -> Unit) {
    val values = remember { mutableStateMapOf<String, String>() }
    SettingsCard(title = stringResource(R.string.forge_body_circumferences), blurb = stringResource(R.string.forge_body_leave_empty)) {
        (b.measured + b.unmeasured).forEach { site ->
            Column(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space1), verticalArrangement = Arrangement.spacedBy(2.dp1)) {
                OutlinedTextField(value = values[site.key] ?: "", label = { Text(site.label) },
                                  onValueChange = { v -> values[site.key] = v.filter { it.isDigit() || it == '.' || it == ',' }.take(6) },
                                  singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                                  suffix = { Text("cm") }, modifier = Modifier.fillMaxWidth(), colors = forgeFieldColors())
                site.guidance?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
            }
        }
        Row {
            TextButton(onClick = onCancel) { Text(stringResource(R.string.forge_body_cancel)) }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = {
                onSave(values.mapNotNull { (k, v) -> v.replace(',', '.').toDoubleOrNull()?.takeIf { it > 0 }?.let { k to it } }.toMap())
            }) { Text(stringResource(R.string.forge_energy_save)) }
        }
    }
}

private val Int.dp1 get() = androidx.compose.ui.unit.Dp(this.toFloat())

/** A stored weight (kg) as the wearer's units show it. */
@Composable
private fun weightLabel(kg: Double, units: com.noop.ui.UnitSystem): String =
    if (units == com.noop.ui.UnitSystem.IMPERIAL) stringResource(R.string.forge_body_lb, one(com.noop.ui.UnitFormatter.kgToPounds(kg)))
    else stringResource(R.string.forge_body_kg, one(kg))

/** The typed weight in kilograms: pounds converted for an imperial wearer; null when it is not a number. */
internal fun weightForStore(text: String, units: com.noop.ui.UnitSystem): Double? =
    text.replace(',', '.').toDoubleOrNull()?.takeIf { it.isFinite() }?.let { TrainingSetInput.massForStore(it, units) }

/** A day key as "12 Nov", as iOS's `dayText`. */
private fun dayText(day: String): String = runCatching {
    val locale = Locale.getDefault()
    java.time.LocalDate.parse(day).format(java.time.format.DateTimeFormatter.ofPattern(
        android.text.format.DateFormat.getBestDateTimePattern(locale, "dMMM"), locale))
}.getOrDefault(day)

private fun one(v: Double): String =
    NumberFormat.getNumberInstance(Locale.getDefault()).apply { minimumFractionDigits = 1; maximumFractionDigits = 1 }.format(v)

private fun signed(v: Double): String = (if (v > 0) "+" else if (v < 0) "−" else "") + one(kotlin.math.abs(v))
