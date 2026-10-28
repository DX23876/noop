package com.noop.ui.forge

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreEcg
import com.noop.core.CoreRead
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date
import kotlin.math.roundToInt

/**
 * Fork (DX23876), Android parity plan 2.3: saved WHOOP MG ECGs after `EcgReadingListView` and `EcgReadingDetailView`:
 * the list, and a reading with the strap's result, its strip on ECG paper, rhythm, variability, the average beat and
 * its intervals. The limits and intended use stay one tap away behind the info button, as on iOS. Recording needs
 * the strap's Bluetooth path on Android and is not offered yet.
 */
@Composable
internal fun ForgeEcgPage(onBack: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var readings by remember { mutableStateOf<List<CoreEcg.Reading>?>(null) }
    var open by remember { mutableStateOf<CoreEcg.Reading?>(null) }
    var info by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<CoreEcg.Reading?>(null) }
    LaunchedEffect(Unit) { readings = withContext(Dispatchers.IO) { CoreRead.open(context); CoreEcg.readings() } }
    androidx.activity.compose.BackHandler(enabled = open != null) { open = null }
    val infoButton: @Composable () -> Unit = {
        IconButton(onClick = { info = true }) {
            Icon(Icons.Rounded.Info, contentDescription = stringResource(R.string.forge_ecg_limits), tint = Forge.colors.accent)
        }
    }
    val current = open
    if (current != null) {
        EcgDetail(current, onBack = { open = null }, infoButton)
    } else {
        SettingsColumn {
            PageTitle(stringResource(R.string.forge_ecg_title), onBack, infoButton)
            val list = readings ?: return@SettingsColumn
            SettingsCard(title = stringResource(R.string.forge_ecg_whoop_mg), blurb = null) {
                if (list.isEmpty()) {
                    Text(stringResource(R.string.forge_ecg_empty), style = Forge.type.body, color = Forge.colors.textSecondary)
                    Text(stringResource(R.string.forge_ecg_android_note), style = Forge.type.footnote, color = Forge.colors.textTertiary)
                }
                list.forEachIndexed { i, r ->
                    Row(Modifier.fillMaxWidth().clickable { open = r }.padding(vertical = ForgeMetrics.space2),
                        verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(r.title, style = Forge.type.body, color = toneColor(r.tone))
                            Text(dateTime(r.startTs), style = Forge.type.caption, color = Forge.colors.textSecondary)
                        }
                        r.averageHr?.let { Text(stringResource(R.string.forge_ecg_bpm, it), style = Forge.type.body, color = Forge.colors.textSecondary) }
                        IconButton(onClick = { deleting = r }) {
                            Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.forge_ecg_delete),
                                 tint = Forge.colors.textTertiary)
                        }
                    }
                    if (i < list.lastIndex) RowDivider()
                }
            }
        }
    }
    deleting?.let { r ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text(r.title) },
            text = { Text(dateTime(r.startTs)) },
            confirmButton = {
                TextButton(onClick = {
                    deleting = null
                    scope.launch { withContext(Dispatchers.IO) { CoreEcg.delete(r.id) }?.let { readings = it } }
                }) { Text(stringResource(R.string.forge_ecg_delete), color = ForgeTokens.Color.systemRed.resolve()) }
            },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text(stringResource(R.string.forge_bp_cancel)) } },
        )
    }
    if (info) {
        AlertDialog(
            onDismissRequest = { info = false },
            title = { Text(stringResource(R.string.forge_ecg_limits)) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                    Text(stringResource(R.string.forge_ecg_experimental), style = Forge.type.caption,
                         color = ForgeTokens.Color.systemOrange.resolve())
                    ECG_POINTS.forEach { (title, text) ->
                        Column {
                            Text(stringResource(title), style = Forge.type.headline)
                            Text(stringResource(text), style = Forge.type.footnote)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { info = false }) { Text(stringResource(R.string.forge_ecg_done)) } },
        )
    }
}

private val ECG_POINTS = listOf(
    R.string.forge_ecg_point0_title to R.string.forge_ecg_point0_text, R.string.forge_ecg_point1_title to R.string.forge_ecg_point1_text,
    R.string.forge_ecg_point2_title to R.string.forge_ecg_point2_text, R.string.forge_ecg_point3_title to R.string.forge_ecg_point3_text,
    R.string.forge_ecg_point4_title to R.string.forge_ecg_point4_text, R.string.forge_ecg_point5_title to R.string.forge_ecg_point5_text,
    R.string.forge_ecg_point6_title to R.string.forge_ecg_point6_text, R.string.forge_ecg_point7_title to R.string.forge_ecg_point7_text,
)

@Composable
private fun EcgDetail(reading: CoreEcg.Reading, onBack: () -> Unit, infoButton: @Composable () -> Unit) {
    var detail by remember { mutableStateOf<CoreEcg.Detail?>(null) }
    LaunchedEffect(reading.id) { detail = withContext(Dispatchers.IO) { CoreEcg.reading(reading.id) } }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_ecg_reading), onBack, infoButton)
        SettingsCard(title = null, blurb = null) {
            Text(reading.title, style = Forge.type.headline, color = toneColor(reading.tone))
            Text(dateTime(reading.startTs), style = Forge.type.caption, color = Forge.colors.textSecondary)
            reading.unreadable.forEach { Text(it, style = Forge.type.footnote, color = Forge.colors.textSecondary) }
            Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4), modifier = Modifier.padding(top = ForgeMetrics.space2)) {
                Stat(stringResource(R.string.forge_ecg_hr), reading.averageHr?.toString() ?: "–", "bpm")
                Stat(stringResource(R.string.forge_ecg_hrv), reading.variability?.toString() ?: "–", "ms")
                Stat(stringResource(R.string.forge_ecg_length), reading.seconds.toString(), "s")
            }
        }
        val d = detail ?: return@SettingsColumn
        Strip(d.samples)
        Text(stringResource(R.string.forge_ecg_scale), style = Forge.type.caption, color = Forge.colors.textTertiary)
        val a = d.analysis
        if (a == null) {
            Text(stringResource(R.string.forge_ecg_too_few), style = Forge.type.subhead, color = Forge.colors.textSecondary)
        } else {
            SettingsCard(title = stringResource(R.string.forge_ecg_rhythm), blurb = null) {
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
                    Stat(stringResource(R.string.forge_ecg_average), a.meanHeartRate.roundToInt().toString(), "bpm")
                    Stat(stringResource(R.string.forge_ecg_lowest), a.minHeartRate.roundToInt().toString(), "bpm")
                    Stat(stringResource(R.string.forge_ecg_highest), a.maxHeartRate.roundToInt().toString(), "bpm")
                }
                Text(if (a.irregularBeats == 0) stringResource(R.string.forge_ecg_no_irregular)
                     else stringResource(R.string.forge_ecg_irregular, a.irregularBeats),
                     style = Forge.type.subhead, color = Forge.colors.textSecondary)
            }
            SettingsCard(title = stringResource(R.string.forge_ecg_variability), blurb = null) {
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
                    Stat("RMSSD", a.rmssdMs?.roundToInt()?.toString() ?: "–", "ms")
                    Stat("SDNN", a.sdnnMs?.roundToInt()?.toString() ?: "–", "ms")
                    Stat("pNN50", a.pnn50?.roundToInt()?.toString() ?: "–", "%")
                }
            }
            if (a.template.isNotEmpty()) {
                SettingsCard(title = stringResource(R.string.forge_ecg_avg_beat),
                             blurb = stringResource(R.string.forge_ecg_from_beats, a.beatsAveraged, a.beatsDetected)) {
                    AverageBeat(a)
                }
                SettingsCard(title = stringResource(R.string.forge_ecg_intervals), blurb = null) {
                    Interval(stringResource(R.string.forge_ecg_pr), a.prMs, stringResource(R.string.forge_ecg_pr_typ))
                    RowDivider()
                    Interval(stringResource(R.string.forge_ecg_qrs), a.qrsMs, stringResource(R.string.forge_ecg_qrs_typ))
                    RowDivider()
                    Interval(stringResource(R.string.forge_ecg_qt), a.qtMs, null)
                    RowDivider()
                    Interval(stringResource(R.string.forge_ecg_qtc), a.qtcFridericiaMs, stringResource(R.string.forge_ecg_qtc_typ))
                }
                Text(stringResource(R.string.forge_ecg_experimental_note), style = Forge.type.footnote, color = Forge.colors.textTertiary)
            }
        }
        SettingsCard(title = null, blurb = null) {
            Fact(stringResource(R.string.forge_ecg_wrist),
                 stringResource(if (reading.wrist == "right") R.string.forge_ecg_right else R.string.forge_ecg_left))
            Fact(stringResource(R.string.forge_ecg_result_code), reading.resultCode.toString())
            reading.quality?.let { Fact(stringResource(R.string.forge_ecg_quality), stringResource(R.string.forge_ecg_quality_of, it)) }
            if (reading.missingSegments > 0) Fact(stringResource(R.string.forge_ecg_lost), reading.missingSegments.toString())
            if (reading.interruptions > 0) Fact(stringResource(R.string.forge_ecg_contact), reading.interruptions.toString())
            if (reading.status == "inconclusive") {
                Fact(stringResource(R.string.forge_ecg_status), stringResource(R.string.forge_ecg_inconclusive_retry))
            }
        }
    }
}

@Composable
private fun Stat(label: String, value: String, unit: String) {
    Column {
        Text(label, style = Forge.type.caption, color = Forge.colors.textSecondary)
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, style = Forge.type.title2, color = Forge.colors.text)
            Text(stringResource(R.string.forge_join_space, "", unit), style = Forge.type.caption, color = Forge.colors.textTertiary, modifier = Modifier.padding(bottom = 3.dp))
        }
    }
}

@Composable
private fun Interval(label: String, ms: Double?, typical: String?) {
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, style = Forge.type.body, color = Forge.colors.text)
            typical?.let { Text(it, style = Forge.type.caption, color = Forge.colors.textTertiary) }
        }
        if (ms != null) Text(stringResource(R.string.forge_ecg_ms, ms.roundToInt()), style = Forge.type.body, color = Forge.colors.text)
        else Text(stringResource(R.string.forge_ecg_not_measurable), style = Forge.type.caption, color = Forge.colors.textTertiary)
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2)) {
        Text(label, style = Forge.type.body, color = Forge.colors.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = Forge.type.body, color = Forge.colors.text)
    }
}

/** ECG paper: 1 mm squares, 5 mm squares darker, at 25 mm/s and 10 mm/mV (`EcgPaper`). */
private fun DrawScope.paper(pxPerMm: Float, minor: Color, major: Color) {
    var i = 0
    var x = 0f
    while (x <= size.width) { drawLine(if (i % 5 == 0) major else minor, Offset(x, 0f), Offset(x, size.height)); x += pxPerMm; i++ }
    i = 0
    var y = 0f
    while (y <= size.height) { drawLine(if (i % 5 == 0) major else minor, Offset(0f, y), Offset(size.width, y)); y += pxPerMm; i++ }
}

/** The whole strip on paper, scrolled sideways: 25 mm per second, 10 mm per millivolt (samples are microvolts). */
@Composable
private fun Strip(samples: List<Int?>) {
    val ink = Forge.colors.text
    val minor = ForgeTokens.Color.systemRed.resolve().copy(alpha = 0.12f)
    val major = ForgeTokens.Color.systemRed.resolve().copy(alpha = 0.28f)
    val pxPerMm = with(androidx.compose.ui.platform.LocalDensity.current) { 4.dp.toPx() }
    val seconds = samples.size / 100f
    val widthDp = with(androidx.compose.ui.platform.LocalDensity.current) { (seconds * 25 * pxPerMm).toDp() }
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(ForgeMetrics.groupedRadius)).background(Forge.colors.surface)
            .horizontalScroll(rememberScrollState())) {
        Canvas(Modifier.width(widthDp).height(40.dp * 4)) {
            paper(pxPerMm, minor, major)
            val baseline = size.height / 2
            val path = Path()
            var pen = false
            samples.forEachIndexed { i, s ->
                if (s == null) { pen = false; return@forEachIndexed }
                val x = i / 100f * 25 * pxPerMm
                val y = baseline - s / 1000f * 10 * pxPerMm
                if (pen) path.lineTo(x, y) else path.moveTo(x, y)
                pen = true
            }
            drawPath(path, ink, style = Stroke(width = 1.2.dp.toPx()))
        }
    }
}

/** The median beat on enlarged paper, with P, Q, J and T marked where the intervals are measured. */
@Composable
private fun AverageBeat(a: CoreEcg.Analysis) {
    val ink = Forge.colors.text
    val accent = Forge.colors.accent
    val minor = ForgeTokens.Color.systemRed.resolve().copy(alpha = 0.12f)
    val major = ForgeTokens.Color.systemRed.resolve().copy(alpha = 0.28f)
    val hi = (a.template.maxOrNull() ?: 0.0) / 1000; val lo = (a.template.minOrNull() ?: 0.0) / 1000
    val top = Math.ceil(maxOf(0.5, hi * 1.15) * 2) / 2; val bottom = Math.ceil(maxOf(0.5, -lo * 1.15) * 2) / 2
    val spanMm = a.template.size / 100f * 25
    val heightMm = ((top + bottom) * 10).toFloat()
    Canvas(Modifier.fillMaxWidth().height(180.dp).clip(RoundedCornerShape(ForgeMetrics.groupedRadius))) {
        val ppm = minOf(size.width / spanMm, size.height / heightMm)
        paper(ppm, minor, major)
        val baseline = (top * 10 * ppm).toFloat()
        val pxPerSample = 25 * ppm / 100
        val path = Path()
        a.template.forEachIndexed { i, v ->
            val x = i * pxPerSample; val y = baseline - (v / 1000 * 10 * ppm).toFloat()
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        drawPath(path, ink, style = Stroke(width = 1.5.dp.toPx()))
        a.fiducialsMs.forEach { (_, ms) ->
            val x = ((a.templateRIndex + ms / 1000 * 100) * pxPerSample).toFloat()
            drawLine(accent, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1.dp.toPx(),
                     pathEffect = PathEffect.dashPathEffect(floatArrayOf(6f, 6f)))
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        a.fiducialsMs.forEach { (label, _) -> Text(label, style = Forge.type.caption, color = accent) }
    }
}

@Composable
private fun toneColor(tone: String) = when (tone) {
    "positive" -> ForgeTokens.Color.systemGreen.resolve()
    "critical" -> ForgeTokens.Color.systemRed.resolve()
    "warning" -> ForgeTokens.Color.systemOrange.resolve()
    else -> Forge.colors.textSecondary
}

private fun dateTime(ts: Long): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ts * 1000))
