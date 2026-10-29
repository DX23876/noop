package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AddCircle
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.EditNote
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.MoreHoriz
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.core.CoreTraining
import com.noop.ui.UnitFormatter
import com.noop.ui.UnitSystem
import kotlinx.coroutines.delay
import java.text.NumberFormat

/*
 * Fork (DX23876), Android parity: the strength logger drawn as iOS draws it (`NativeWorkoutLoggerView`,
 * `WorkoutLoggerHeader`, `WorkoutRestDock`, `TrainingHubView.exerciseCard` / `setRow`). The column widths are
 * iOS's `SetColumns`, so a row reads the same on both phones.
 */

internal object LoggerColumns {
    val spacing = 4.dp
    val set = 32.dp
    val previous = 52.dp
    val weight = 64.dp
    val reps = 52.dp
    val effort = 44.dp
    val check = 44.dp
}

/** The top bar: minimize, the workout's name, and the options menu beside Finish in one capsule. */
@Composable
internal fun LoggerTopBar(title: String, onMinimize: () -> Unit, onFinish: () -> Unit,
                          menu: @Composable (dismiss: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(top = ForgeMetrics.space2), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
        Box(Modifier.size(44.dp).background(Forge.colors.surfaceTop, CircleShape).border(1.dp, Forge.colors.border, CircleShape)
                .clickable(onClick = onMinimize), contentAlignment = Alignment.Center) {
            Icon(Icons.Rounded.KeyboardArrowDown, stringResource(R.string.forge_lg_minimize), tint = Forge.colors.text)
        }
        Text(title, style = Forge.type.headline, color = Forge.colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.weight(1f))
        Row(Modifier.height(44.dp).background(Forge.colors.surfaceTop, RoundedCornerShape(50))
                .border(1.dp, Forge.colors.border, RoundedCornerShape(50)).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Box {
                Box(Modifier.size(36.dp).clickable { open = true }, contentAlignment = Alignment.Center) {
                    Box(Modifier.size(24.dp).border(1.5.dp, Forge.colors.text, CircleShape), contentAlignment = Alignment.Center) {
                        Icon(Icons.Rounded.MoreHoriz, stringResource(R.string.forge_wl_options), tint = Forge.colors.text,
                             modifier = Modifier.size(16.dp))
                    }
                }
                androidx.compose.material3.DropdownMenu(open, onDismissRequest = { open = false }) { menu { open = false } }
            }
            Text(stringResource(R.string.forge_lg_finish), style = Forge.type.headline, color = Forge.colors.charge,
                 modifier = Modifier.clickable(onClick = onFinish).padding(horizontal = 10.dp, vertical = 8.dp))
        }
    }
}

/** Duration (or Paused), Volume and Sets in one slim row with the pause button, and the share of sets done. */
@Composable
internal fun LoggerHeaderCard(figures: CoreTraining.Figures?, units: UnitSystem, onPause: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(figures) { while (true) { now = System.currentTimeMillis(); delay(1_000) } }
    val f = figures
    val paused = f?.paused == true
    val seconds = (f?.activeSeconds ?: 0) + if (f != null && !paused) ((now - f.fetchedAtMs) / 1000).coerceAtLeast(0) else 0
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            HeaderStat(stringResource(if (paused) R.string.forge_lg_paused else R.string.forge_lg_duration), workoutClock(seconds),
                       if (paused) ForgeTokens.StrandPalette.statusWarning.resolve() else null)
            HeaderStat(stringResource(R.string.forge_lg_volume), volumeText(f?.volumeKg ?: 0.0, units))
            HeaderStat(stringResource(R.string.forge_lg_sets),
                       stringResource(R.string.forge_count_of, f?.completedSets ?: 0, f?.totalSets ?: 0))
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(40.dp).background(Forge.colors.inset, CircleShape).clickable(onClick = onPause),
                contentAlignment = Alignment.Center) {
                Icon(if (paused) Icons.Rounded.PlayArrow else Icons.Rounded.Pause,
                     stringResource(if (paused) R.string.forge_lg_resume else R.string.forge_lg_pause), tint = Forge.colors.text)
            }
        }
        Spacer(Modifier.height(ForgeMetrics.space3))
        LoggerBar((f?.completedSets ?: 0).toFloat() / (f?.totalSets ?: 0).coerceAtLeast(1), Forge.colors.charge)
    }
}

/** A thin progress bar on the inset track, as SwiftUI's linear `ProgressView`. */
@Composable
internal fun LoggerBar(fraction: Float, color: Color) {
    Box(Modifier.fillMaxWidth().height(4.dp).background(Forge.colors.inset, RoundedCornerShape(2.dp))) {
        Box(Modifier.fillMaxWidth(fraction.coerceIn(0f, 1f)).height(4.dp).background(color, RoundedCornerShape(2.dp)))
    }
}

@Composable
private fun HeaderStat(title: String, value: String, titleColor: Color? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(title, style = Forge.type.caption, color = titleColor ?: Forge.colors.textTertiary, maxLines = 1)
        Text(value, style = Forge.type.headline.copy(fontSize = 17.sp, fontFeatureSettings = "tnum"), color = Forge.colors.text,
             maxLines = 1)
    }
}

/** iOS `ActiveWorkoutClock.clock`: m:ss, or h:mm:ss from an hour. */
internal fun workoutClock(seconds: Long): String {
    val h = seconds / 3600; val m = (seconds % 3600) / 60; val s = seconds % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/** iOS `TrainingPreferences.formattedVolume`: whole units with the unit symbol. */
internal fun volumeText(kg: Double, units: UnitSystem): String =
    "${NumberFormat.getIntegerInstance().format(Math.round(TrainingSetInput.massForInput(kg, units)))} ${UnitFormatter.massUnit(units)}"

/** A capsule chip under the exercise's name ("Rest: 2 min", "Note"), as iOS `chipLabel`. */
@Composable
internal fun LoggerChip(title: String, icon: ImageVector, onClick: () -> Unit) {
    Row(Modifier.background(Forge.colors.inset, RoundedCornerShape(50)).clickable(onClick = onClick)
            .padding(horizontal = ForgeMetrics.space3, vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, contentDescription = null, tint = Forge.colors.textSecondary, modifier = Modifier.size(14.dp))
        Text(title, style = Forge.type.caption.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.textSecondary,
             maxLines = 1)
    }
}

/** "2 min, 30 sec" in the reader's language, "Off" for none (iOS `TrainingRestText.text`). */
@Composable
internal fun restText(seconds: Int): String {
    if (seconds <= 0) return stringResource(R.string.forge_lg_off)
    val m = seconds / 60; val s = seconds % 60
    val parts = buildList {
        if (m > 0) add(android.icu.util.Measure(m, android.icu.util.MeasureUnit.MINUTE))
        if (s > 0) add(android.icu.util.Measure(s, android.icu.util.MeasureUnit.SECOND))
    }
    return android.icu.text.MeasureFormat.getInstance(java.util.Locale.getDefault(),
        android.icu.text.MeasureFormat.FormatWidth.SHORT).formatMeasures(*parts.toTypedArray())
}

/** Quarter minutes up to five, then half minutes up to ten (iOS `TrainingRestText.choices`). */
internal val REST_CHOICES: List<Int> = listOf(0) + (15..300 step 15) + (330..600 step 30)

@Composable
internal fun RestPickerDialog(title: String, seconds: Int, onPick: (Int) -> Unit, onDismiss: () -> Unit) {
    var index by remember { mutableStateOf(REST_CHOICES.indexOf(seconds).takeIf { it >= 0 } ?: REST_CHOICES.indexOfFirst { it >= seconds }.coerceAtLeast(0)) }
    AlertDialog(onDismissRequest = onDismiss, containerColor = Forge.colors.surface,
        title = { Text(title, style = Forge.type.headline, color = Forge.colors.text) },
        text = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(restText(REST_CHOICES[index]), style = Forge.type.title2, color = Forge.colors.text, modifier = Modifier.weight(1f))
                Stepper("", onMinus = { index = (index - 1).coerceAtLeast(0) },
                        onPlus = { index = (index + 1).coerceAtMost(REST_CHOICES.lastIndex) })
            }
        },
        confirmButton = { TextButton(onClick = { onPick(REST_CHOICES[index]); onDismiss() }) { Text(stringResource(R.string.forge_lg_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_lg_cancel)) } })
}

@Composable
internal fun NoteDialog(title: String, note: String, onSave: (String) -> Unit, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf(note) }
    AlertDialog(onDismissRequest = onDismiss, containerColor = Forge.colors.surface,
        title = { Text(title, style = Forge.type.headline, color = Forge.colors.text) },
        text = {
            BasicTextField(text, { text = it }, textStyle = Forge.type.body.copy(color = Forge.colors.text),
                           cursorBrush = SolidColor(Forge.colors.accent),
                           modifier = Modifier.fillMaxWidth().heightIn(min = 96.dp)
                               .background(Forge.colors.inset, RoundedCornerShape(ForgeMetrics.groupedRadius)).padding(12.dp))
        },
        confirmButton = { TextButton(onClick = { onSave(text); onDismiss() }) { Text(stringResource(R.string.forge_lg_save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.forge_lg_cancel)) } })
}

/** The exercise's name in the accent, its main muscle under it, and the options menu at the end. */
@Composable
internal fun LoggerExerciseHeader(title: String, muscle: String?, trailing: @Composable RowScope.() -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, style = Forge.type.headline, color = Forge.colors.accent)
            if (!muscle.isNullOrEmpty()) Text(muscle, style = Forge.type.caption, color = Forge.colors.textTertiary)
        }
        trailing()
    }
}

@Composable
internal fun LoggerChips(restLabel: String, onRest: () -> Unit, onNote: () -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
        LoggerChip(restLabel, Icons.Rounded.Timer, onRest)
        LoggerChip(stringResource(R.string.forge_lg_note), Icons.Rounded.EditNote, onNote)
    }
}

/** The column titles over the sets, each as wide as the control it names. */
@Composable
internal fun LoggerSetHeader(columns: List<TrainingSetInput>, showsPrevious: Boolean, effortScale: String) {
    @Composable fun label(text: String, modifier: Modifier) =
        Text(text, style = Forge.type.caption.copy(fontWeight = FontWeight.Medium), color = Forge.colors.textTertiary,
             textAlign = TextAlign.Center, maxLines = 1, modifier = modifier)
    Row(horizontalArrangement = Arrangement.spacedBy(LoggerColumns.spacing), verticalAlignment = Alignment.CenterVertically) {
        label(stringResource(R.string.forge_lg_col_set), Modifier.width(LoggerColumns.set))
        if (showsPrevious) label(stringResource(R.string.forge_lg_col_previous), Modifier.weight(1f))
        columns.forEach { field ->
            label(columnTitle(field), fieldWidth(field, showsPrevious))
        }
        if (effortScale != "off") label(stringResource(if (effortScale == "rir") R.string.forge_lg_col_rir else R.string.forge_lg_col_rpe),
                                        Modifier.width(LoggerColumns.effort))
        Spacer(Modifier.width(LoggerColumns.check))
    }
}

@Composable
private fun columnTitle(field: TrainingSetInput): String = when (field) {
    TrainingSetInput.Weight -> stringResource(R.string.forge_lg_col_weight)
    TrainingSetInput.Reps -> stringResource(R.string.forge_lg_col_reps)
    TrainingSetInput.Left -> stringResource(R.string.forge_library_left).uppercase()
    TrainingSetInput.Right -> stringResource(R.string.forge_library_right).uppercase()
    TrainingSetInput.Seconds -> stringResource(R.string.forge_lg_col_time)
    TrainingSetInput.Distance -> stringResource(R.string.forge_lg_col_dist)
}

/** Weight and reps keep iOS's fixed widths beside the PREVIOUS column; otherwise the fields share the row. */
@Composable
private fun RowScope.fieldWidth(field: TrainingSetInput, showsPrevious: Boolean): Modifier = when {
    showsPrevious && field == TrainingSetInput.Weight -> Modifier.width(LoggerColumns.weight)
    showsPrevious -> Modifier.width(LoggerColumns.reps)
    else -> Modifier.weight(1f)
}

/** iOS shows the last session beside load and repetition sets only. */
internal fun showsPreviousColumn(mode: String): Boolean =
    mode in setOf("weight_reps", "weighted_bodyweight", "assisted_bodyweight", "bodyweight_reps", "repetitions")

/**
 * One set: its badge (number or W), the last session's set, the value pills, the effort badge and the check.
 * The next set to log is ringed in Charge green; a completed set dims a little.
 */
@Composable
internal fun LoggerSetRow(number: Int?, set: CoreTraining.DraftSet, columns: List<TrainingSetInput>,
                          previous: CoreTraining.PreviousSet?, showsPrevious: Boolean, isNext: Boolean,
                          massUnits: UnitSystem, distanceUnits: UnitSystem, effortScale: String,
                          onEffort: () -> Unit, onChange: (CoreTraining.DraftSet) -> Unit) {
    val context = LocalContext.current
    val initialWeight = remember(set.id, set.weightKg, massUnits) { set.weightKg?.let { decimal(TrainingSetInput.massForInput(it, massUnits)) } ?: "" }
    val initialDistance = remember(set.id, set.distanceM, distanceUnits) { set.distanceM?.let { decimal(TrainingSetInput.distanceForInput(it, distanceUnits)) } ?: "" }
    var weight by remember(set.id, set.weightKg, massUnits) { mutableStateOf(initialWeight) }
    var reps by remember(set.id, set.reps) { mutableStateOf(set.reps?.toString() ?: "") }
    var left by remember(set.id, set.leftReps, set.reps) { mutableStateOf((set.leftReps ?: set.reps)?.toString() ?: "") }
    var right by remember(set.id, set.rightReps, set.reps) { mutableStateOf((set.rightReps ?: set.reps)?.toString() ?: "") }
    var duration by remember(set.id, set.durationS) { mutableStateOf(set.durationS?.toString() ?: "") }
    var distance by remember(set.id, set.distanceM, distanceUnits) { mutableStateOf(initialDistance) }
    fun commit(done: Boolean = set.done) = onChange(set.copy(
        weightKg = if (TrainingSetInput.Weight in columns) TrainingSetInput.editedMeasurement(set.weightKg, initialWeight, weight) { TrainingSetInput.massForStore(it, massUnits) } else set.weightKg,
        reps = if (TrainingSetInput.Reps in columns) reps.toIntOrNull() else if (TrainingSetInput.Left in columns) null else set.reps,
        leftReps = if (TrainingSetInput.Left in columns) left.toIntOrNull() else set.leftReps,
        rightReps = if (TrainingSetInput.Right in columns) right.toIntOrNull() else set.rightReps,
        durationS = if (TrainingSetInput.Seconds in columns) duration.toIntOrNull() else set.durationS,
        distanceM = if (TrainingSetInput.Distance in columns) TrainingSetInput.editedMeasurement(set.distanceM, initialDistance, distance) { TrainingSetInput.distanceForStore(it, distanceUnits) } else set.distanceM,
        done = done))
    val charge = Forge.colors.charge
    val shape = RoundedCornerShape(ForgeMetrics.groupedRadius)
    Row(Modifier.fillMaxWidth()
            .then(if (isNext) Modifier.background(charge.copy(alpha = 0.10f), shape).border(1.dp, charge.copy(alpha = 0.45f), shape) else Modifier)
            .alpha(if (set.done) 0.72f else 1f).padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(LoggerColumns.spacing), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(LoggerColumns.set).background(Forge.colors.inset, RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
            Text(if (set.warmup) stringResource(R.string.forge_lg_warmup_badge) else number?.toString() ?: "—", style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold),
                 color = if (set.warmup) ForgeTokens.StrandPalette.metricAmber.resolve() else Forge.colors.text)
        }
        if (showsPrevious) {
            val text = previous?.let { previousText(it, columns, massUnits) } ?: "—"
            Box(Modifier.weight(1f).heightIn(min = 44.dp)
                     .clickable(enabled = previous != null && !set.done) {
                         // Tapping the last session's set copies its numbers into this one, as iOS `previousCell`.
                         val p = previous ?: return@clickable
                         if (TrainingSetInput.Weight in columns) p.weightKg?.let { weight = decimal(TrainingSetInput.massForInput(it, massUnits)) }
                         if (TrainingSetInput.Left in columns) { (p.leftReps ?: p.reps)?.let { left = it.toString() }; (p.rightReps ?: p.reps)?.let { right = it.toString() } }
                         else p.reps?.let { reps = it.toString() }
                         commit()
                     }, contentAlignment = Alignment.Center) {
                Text(text, style = Forge.type.caption.copy(fontFeatureSettings = "tnum"), color = Forge.colors.textTertiary,
                     textAlign = TextAlign.Center, maxLines = 1)
            }
        }
        columns.forEach { field ->
            val value = when (field) {
                TrainingSetInput.Weight -> weight; TrainingSetInput.Reps -> reps; TrainingSetInput.Left -> left
                TrainingSetInput.Right -> right; TrainingSetInput.Seconds -> duration; TrainingSetInput.Distance -> distance
            }
            val decimalField = field == TrainingSetInput.Weight || field == TrainingSetInput.Distance
            ValuePill(value, decimalField, fieldWidth(field, showsPrevious), onChange = { input ->
                val n = input.filter { it.isDigit() || (decimalField && (it == '.' || it == ',')) }
                when (field) {
                    TrainingSetInput.Weight -> weight = n; TrainingSetInput.Reps -> reps = n; TrainingSetInput.Left -> left = n
                    TrainingSetInput.Right -> right = n; TrainingSetInput.Seconds -> duration = n; TrainingSetInput.Distance -> distance = n
                }
            }, onDone = { commit() })
        }
        if (effortScale != "off") {
            val rated = set.effortValue?.takeIf { set.effortScale != null }
            val label = stringResource(if (effortScale == "rir") R.string.forge_ef_rir_label else R.string.forge_ef_rpe)
            val stateText = rated?.let(SetEffort::format) ?: stringResource(R.string.forge_ef_not_rated)
            val described = stringResource(R.string.forge_label_value, label, stateText)
            EffortBadge((if (set.effortScale == "rir") "R" else "") + (rated?.let(SetEffort::format) ?: "—"),
                        rated?.let { SetEffort.color(SetEffort.level(set.effortScale!!, it)) },
                        Modifier.size(LoggerColumns.effort, 32.dp).clickable(onClick = onEffort)
                            .semantics { contentDescription = described })
        }
        Box(Modifier.size(LoggerColumns.check).clickable { commit(!set.done) }
                .semantics { contentDescription = context.getString(if (set.done) R.string.forge_lg_mark_open else R.string.forge_lg_mark_done) },
            contentAlignment = Alignment.Center) {
            when {
                set.done -> Box(Modifier.size(26.dp).background(charge, CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
                }
                isNext -> Box(Modifier.size(26.dp).border(1.5.dp, charge, CircleShape), contentAlignment = Alignment.Center) {
                    Icon(Icons.Rounded.Check, contentDescription = null, tint = charge, modifier = Modifier.size(16.dp))
                }
                else -> Box(Modifier.size(26.dp).border(1.5.dp, Forge.colors.textTertiary, CircleShape))
            }
        }
    }
}

/** A value in its inset pill, centred, committed on Done or when the field loses focus. */
@Composable
private fun ValuePill(value: String, decimal: Boolean, modifier: Modifier, onChange: (String) -> Unit, onDone: () -> Unit) {
    var focused by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(ForgeMetrics.groupedRadius)
    BasicTextField(value, onChange, singleLine = true,
        textStyle = Forge.type.subhead.copy(color = Forge.colors.text, textAlign = TextAlign.Center, fontFeatureSettings = "tnum"),
        cursorBrush = SolidColor(Forge.colors.accent),
        keyboardOptions = KeyboardOptions(keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Number, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        modifier = modifier.height(40.dp).background(Forge.colors.inset, shape)
            .border(1.5.dp, if (focused) Forge.colors.accent else Color.Transparent, shape)
            .onFocusEdge { now -> if (focused && !now) onDone(); focused = now },
        decorationBox = { inner ->
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                if (value.isEmpty()) Text("—", style = Forge.type.subhead, color = Forge.colors.textTertiary)
                inner()
            }
        })
}

private fun Modifier.onFocusEdge(onChange: (Boolean) -> Unit): Modifier =
    this.onFocusChanged { onChange(it.isFocused) }

private fun decimal(v: Double): String = NumberFormat.getNumberInstance().apply {
    minimumFractionDigits = 0; maximumFractionDigits = 2; isGroupingUsed = false
}.format(v)

/** iOS `TrainingSetText.cell`: "142,5 × 4" for a load, the repetitions alone without one, "L 8 · R 6" per side. */
private fun previousText(p: CoreTraining.PreviousSet, columns: List<TrainingSetInput>, units: UnitSystem): String {
    val reps = if (TrainingSetInput.Left in columns) "${p.leftReps ?: p.reps ?: "—"}/${p.rightReps ?: p.reps ?: "—"}"
               else p.reps?.toString() ?: "—"
    return if (TrainingSetInput.Weight in columns && p.weightKg != null) "${decimal(TrainingSetInput.massForInput(p.weightKg, units))} × $reps" else reps
}

/** Full-width "Add exercise" in the accent's tint, as iOS's bordered button. */
@Composable
internal fun LoggerAddExerciseButton(onClick: () -> Unit) {
    val accent = Forge.colors.accent
    Row(Modifier.fillMaxWidth().background(accent.copy(alpha = 0.16f), RoundedCornerShape(ForgeMetrics.groupedRadius + 6.dp))
            .clickable(onClick = onClick).padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.AddCircle, contentDescription = null, tint = accent, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(ForgeMetrics.space2))
        Text(stringResource(R.string.forge_lg_add_exercise), style = Forge.type.body, color = accent)
    }
}

/** Notes for the whole workout, saved when the field loses focus. */
@Composable
internal fun LoggerNotesCard(note: String?, onSave: (String) -> Unit) {
    var text by remember(note) { mutableStateOf(note.orEmpty()) }
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        BasicTextField(text, { text = it }, textStyle = Forge.type.body.copy(color = Forge.colors.text),
            cursorBrush = SolidColor(Forge.colors.accent),
            modifier = Modifier.fillMaxWidth().onFocusEdge { focused -> if (!focused && text != note.orEmpty()) onSave(text) },
            decorationBox = { inner ->
                Box {
                    if (text.isEmpty()) Text(stringResource(R.string.forge_lg_workout_notes), style = Forge.type.body,
                                             color = Forge.colors.textTertiary)
                    inner()
                }
            })
    }
}
