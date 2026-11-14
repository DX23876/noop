package com.noop.ui.forge

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CorePlans
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

/**
 * A routine in full, as the Apple editor has it: its name, its days, its exercises, and for each one
 * the sets with their repetitions and weights, the rests, a superset, a note and how it should
 * progress.
 *
 * Every change is one operation sent to the core, which applies it and saves. Kotlin holds no copy of
 * the model: what a new set or a new exercise starts out as is decided once, in `CorePlans`, so both
 * platforms add the same thing.
 */
@Composable
internal fun ForgeRoutineEditorPage(routineId: String?, planId: String?, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var detail by remember { mutableStateOf<CorePlans.RoutineDetail?>(null) }
    var id by remember { mutableStateOf(routineId) }
    var reload by remember { mutableStateOf(0) }
    var openExercise by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }

    LaunchedEffect(id, reload) { detail = id?.let { key -> core(context) { CorePlans.routine(key) } } }

    fun edit(op: String, args: JSONObject = JSONObject(), after: () -> Unit = {}) {
        val key = id ?: return
        scope.launch {
            core(context) { CorePlans.editRoutine(op, key, args) }
            reload++
            after()
        }
    }

    if (picking) {
        BackHandler { picking = false }
        ExercisePicker(multiple = true, onBack = { picking = false }) { ids ->
            picking = false
            scope.launch {
                val key = id
                if (key != null) {
                    core(context) {
                        ids.forEach {
                            CorePlans.editRoutine("addExercise", key,
                                                  JSONObject().put("exerciseId", it))
                        }
                    }
                    reload++
                }
            }
        }
        return
    }

    val exercise = detail?.exercises?.firstOrNull { it.id == openExercise }
    if (exercise != null) {
        ExerciseDetailPage(exercise, onBack = { openExercise = null }, onEdit = { op, args ->
            edit(op, args.put("exerciseEntryId", exercise.id))
        })
        return
    }

    BackHandler { onClose() }
    val current = detail
    var title by remember(current?.id) { mutableStateOf(current?.title.orEmpty()) }
    var notes by remember(current?.id) { mutableStateOf(current?.notes.orEmpty()) }

    SettingsColumn {
        PageTitle(if (id == null) stringResource(R.string.forge_training_new_routine)
                  else stringResource(R.string.forge_routine_edit), onClose, trailing = {
            TextButton(enabled = title.isNotBlank(), onClick = {
                scope.launch {
                    val key = id
                    if (key == null) {
                        // A routine that does not exist yet is created in the plan it was opened from.
                        core(context) {
                            CorePlans.editRoutine("create", null, JSONObject().put("title", title.trim())
                                .apply { if (planId != null) put("planId", planId) })
                        }
                        onClose()
                    } else {
                        core(context) {
                            CorePlans.editRoutine("title", key, JSONObject().put("value", title.trim()))
                            CorePlans.editRoutine("notes", key, JSONObject().put("value", notes.trim()))
                        }
                        onClose()
                    }
                }
            }) { Text(stringResource(R.string.forge_training_save), color = Forge.colors.charge,
                      style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold)) }
        })

        OutlinedTextField(value = title, onValueChange = { title = it }, singleLine = true,
                          label = { Text(stringResource(R.string.forge_training_routine_name)) },
                          colors = fieldColors(), modifier = Modifier.fillMaxWidth())
        if (id != null) {
            OutlinedTextField(value = notes, onValueChange = { notes = it },
                              label = { Text(stringResource(R.string.forge_plan_notes)) },
                              colors = fieldColors(), modifier = Modifier.fillMaxWidth())
        }
        current?.planTitle?.let {
            Text(stringResource(R.string.forge_routine_goes_into, it), style = Forge.type.caption,
                 color = Forge.colors.textTertiary)
        }

        if (current != null) {
            // The days belong to this routine's own plan, not to the week being followed.
            val locale = Locale.getDefault()
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (day in 1..7) {
                    val on = day in current.weekdays
                    Box(Modifier.weight(1f).height(36.dp)
                            .background(if (on) Forge.colors.accent else Forge.colors.surface,
                                        RoundedCornerShape(10.dp))
                            .clickable {
                                val days = current.weekdays.toMutableList()
                                if (on) days.remove(day) else days.add(day)
                                edit("weekdays", JSONObject().put("value", JSONArray(days)))
                            },
                        contentAlignment = Alignment.Center) {
                        Text(DayOfWeek.of(day).getDisplayName(TextStyle.SHORT, locale),
                             style = Forge.type.caption,
                             color = if (on) Forge.colors.onAccent else Forge.colors.text, maxLines = 1)
                    }
                }
            }

            if (current.exercises.isNotEmpty()) {
                ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
                    current.exercises.forEachIndexed { index, entry ->
                        Row(Modifier.fillMaxWidth().heightIn(min = 56.dp)
                                .clickable { openExercise = entry.id }
                                .padding(horizontal = ForgeMetrics.cardPadding, vertical = ForgeMetrics.space3),
                            verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(entry.title, style = Forge.type.subhead, color = Forge.colors.text)
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    if (entry.supersetId != null) {
                                        Icon(Icons.Rounded.Link, contentDescription = null,
                                             tint = Forge.colors.charge, modifier = Modifier.size(14.dp))
                                        Spacer(Modifier.width(4.dp))
                                    }
                                    Text(setSummary(entry), style = Forge.type.caption,
                                         color = Forge.colors.textSecondary)
                                }
                            }
                            Text(stringResource(R.string.forge_routine_rest_short, entry.restSeconds),
                                 style = Forge.type.caption, color = Forge.colors.textTertiary)
                        }
                        if (index < current.exercises.lastIndex) HubDivider()
                    }
                }
                Text(stringResource(R.string.forge_routine_about_minutes, current.minutes),
                     style = Forge.type.caption, color = Forge.colors.textTertiary)
            }
            PanelButton(stringResource(R.string.forge_training_add_exercise), Icons.Rounded.Add) {
                picking = true
            }

            // How the whole routine is meant to move, unless an exercise says otherwise.
            ForgeCard(Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_routine_progression), style = Forge.type.headline,
                     color = Forge.colors.text)
                Spacer(Modifier.height(ForgeMetrics.space2))
                ProgressionPicker(current.defaultProgression.policy, allowDefault = false) { policy ->
                    edit("defaultProgression", JSONObject().put("policy", policy))
                }
                HubDivider()
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.forge_routine_exclude), style = Forge.type.subhead,
                         color = Forge.colors.text, modifier = Modifier.weight(1f))
                    Switch(checked = current.excludeFromProgression, onCheckedChange = {
                        edit("excludeFromProgression", JSONObject().put("value", it))
                    })
                }
            }

            TextButton(onClick = { confirmingDelete = true }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.forge_training_delete_routine),
                     color = ForgeTokens.Color.systemRed.resolve())
            }
            if (confirmingDelete) {
                ForgeCard(Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.forge_routine_delete_detail), style = Forge.type.subhead,
                         color = Forge.colors.textSecondary)
                    Spacer(Modifier.height(ForgeMetrics.space3))
                    Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
                        TextButton(onClick = { confirmingDelete = false }) {
                            Text(stringResource(R.string.forge_plan_cancel), color = Forge.colors.text)
                        }
                        TextButton(onClick = { edit("delete") { onClose() } }) {
                            Text(stringResource(R.string.forge_training_delete_routine),
                                 color = ForgeTokens.Color.systemRed.resolve())
                        }
                    }
                }
            }
        }
    }
}

/** One exercise of a routine: its sets, its rests, how it progresses and what it is paired with. */
@Composable
private fun ExerciseDetailPage(entry: CorePlans.RoutineExerciseDetail, onBack: () -> Unit,
                               onEdit: (String, JSONObject) -> Unit) {
    BackHandler { onBack() }
    var note by remember(entry.id) { mutableStateOf(entry.note.orEmpty()) }
    SettingsColumn {
        PageTitle(entry.title, onBack)

        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius, contentPadding = 0.dp) {
            entry.sets.forEachIndexed { index, set ->
                SetRow(set, index + 1,
                       onChange = { args -> onEdit("setValues", args.put("setId", set.id)) },
                       onRemove = { onEdit("removeSet", JSONObject().put("setId", set.id)) })
                if (index < entry.sets.lastIndex) HubDivider()
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3)) {
            PanelButton(stringResource(R.string.forge_routine_add_work_set), Icons.Rounded.Add) {
                onEdit("addSet", JSONObject().put("warmup", false))
            }
            PanelButton(stringResource(R.string.forge_routine_add_warmup_set), Icons.Rounded.Add) {
                onEdit("addSet", JSONObject().put("warmup", true))
            }
        }

        ForgeCard(Modifier.fillMaxWidth()) {
            StepperRowInternal(stringResource(R.string.forge_routine_rest, entry.restSeconds),
                               entry.restSeconds > 0, entry.restSeconds < 600,
                               { onEdit("rest", JSONObject().put("value", entry.restSeconds - 15)) },
                               { onEdit("rest", JSONObject().put("value", entry.restSeconds + 15)) })
            HubDivider()
            val warmupRest = entry.warmupRestSeconds ?: 60
            StepperRowInternal(stringResource(R.string.forge_routine_warmup_rest, warmupRest),
                               warmupRest > 0, warmupRest < 600,
                               { onEdit("warmupRest", JSONObject().put("value", warmupRest - 15)) },
                               { onEdit("warmupRest", JSONObject().put("value", warmupRest + 15)) })
        }

        ForgeCard(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_routine_progression), style = Forge.type.headline,
                 color = Forge.colors.text)
            Spacer(Modifier.height(ForgeMetrics.space2))
            ProgressionPicker(entry.progression?.policy, allowDefault = true) { policy ->
                if (policy == null) onEdit("exerciseProgression", JSONObject())
                else onEdit("exerciseProgression", JSONObject().put("value", true).put("policy", policy))
            }
        }

        ForgeCard(Modifier.fillMaxWidth()) {
            Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable {
                    onEdit("superset", JSONObject())
                }, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Rounded.Link, contentDescription = null,
                     tint = if (entry.supersetId != null) Forge.colors.charge else Forge.colors.textTertiary,
                     modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(if (entry.supersetId != null) stringResource(R.string.forge_routine_superset_remove)
                     else stringResource(R.string.forge_routine_superset_with_next),
                     style = Forge.type.subhead, color = Forge.colors.text)
            }
        }

        OutlinedTextField(value = note, onValueChange = {
                              note = it
                              onEdit("exerciseNote", JSONObject().put("value", it))
                          },
                          label = { Text(stringResource(R.string.forge_routine_note)) },
                          colors = fieldColors(), modifier = Modifier.fillMaxWidth())

        TextButton(onClick = { onEdit("removeExercise", JSONObject()); onBack() },
                   modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.forge_training_remove_exercise),
                 color = ForgeTokens.Color.systemRed.resolve())
        }
    }
}

@Composable
private fun SetRow(set: CorePlans.SetPlan, number: Int, onChange: (JSONObject) -> Unit,
                   onRemove: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .padding(horizontal = ForgeMetrics.cardPadding, vertical = ForgeMetrics.space2),
        verticalAlignment = Alignment.CenterVertically) {
        Text(if (set.isWarmup) stringResource(R.string.forge_routine_warmup_set)
             else stringResource(R.string.forge_routine_set_number, number),
             style = Forge.type.caption, color = Forge.colors.textSecondary,
             modifier = Modifier.width(72.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(setLine(set), style = Forge.type.subhead, color = Forge.colors.text)
        }
        if (set.durationS != null) {
            SmallStep("−") { onChange(JSONObject().put("durationS", (set.durationS - 5).coerceAtLeast(5))) }
            Spacer(Modifier.width(4.dp))
            SmallStep("+") { onChange(JSONObject().put("durationS", set.durationS + 5)) }
        } else {
            SmallStep("−") {
                val low = (set.repsMin ?: 1) - 1
                onChange(JSONObject().put("repsMin", low.coerceAtLeast(1))
                             .put("repsMax", ((set.repsMax ?: low) - 1).coerceAtLeast(low.coerceAtLeast(1))))
            }
            Spacer(Modifier.width(4.dp))
            SmallStep("+") {
                val low = (set.repsMin ?: 1) + 1
                onChange(JSONObject().put("repsMin", low).put("repsMax", ((set.repsMax ?: low) + 1)))
            }
        }
        Spacer(Modifier.width(ForgeMetrics.space2))
        Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.forge_routine_remove_set),
             tint = Forge.colors.textTertiary,
             modifier = Modifier.size(18.dp).clickable(onClick = onRemove))
    }
}

@Composable
private fun setLine(set: CorePlans.SetPlan): String {
    val reps = when {
        set.durationS != null -> stringResource(R.string.forge_routine_seconds, set.durationS)
        set.repsMin != null && set.repsMax != null && set.repsMin != set.repsMax ->
            "${set.repsMin}–${set.repsMax}"
        set.repsMin != null && set.repsMax == null -> "${set.repsMin}+"
        set.repsMin != null -> "${set.repsMin}"
        else -> ""
    }
    val weight = set.weightKg?.takeIf { it > 0 }?.let { " · ${it.toInt()} kg" } ?: ""
    return reps + weight
}

@Composable
private fun setSummary(entry: CorePlans.RoutineExerciseDetail): String {
    val work = entry.sets.filter { !it.isWarmup }
    val first = work.firstOrNull() ?: return stringResource(R.string.forge_routine_no_sets)
    return "${work.size} × " + setLine(first)
}

@Composable
private fun ProgressionPicker(policy: String?, allowDefault: Boolean, onPick: (String?) -> Unit) {
    val options = buildList {
        if (allowDefault) add(null to stringResource(R.string.forge_routine_progression_default))
        add("off" to stringResource(R.string.forge_routine_progression_off))
        add("linear" to stringResource(R.string.forge_routine_progression_linear))
        add("double_progression" to stringResource(R.string.forge_routine_progression_double))
        add("greyskull_lp" to "Greyskull LP")
        add("time" to stringResource(R.string.forge_routine_progression_time))
    }
    options.forEach { (value, label) ->
        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).clickable { onPick(value) },
            verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = Forge.type.subhead,
                 color = if (value == policy) Forge.colors.text else Forge.colors.textSecondary,
                 fontWeight = if (value == policy) FontWeight.SemiBold else FontWeight.Normal,
                 modifier = Modifier.weight(1f))
            if (value == policy) {
                Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Forge.colors.charge,
                     modifier = Modifier.size(18.dp))
            }
        }
    }
}

@Composable
private fun StepperRowInternal(label: String, canDown: Boolean, canUp: Boolean, down: () -> Unit,
                               up: () -> Unit) {
    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Forge.type.subhead, color = Forge.colors.text, modifier = Modifier.weight(1f))
        SmallStep("−", canDown, down)
        Spacer(Modifier.width(ForgeMetrics.space2))
        SmallStep("+", canUp, up)
    }
}

@Composable
private fun SmallStep(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(Modifier.size(32.dp).background(Forge.colors.surfaceTop, CircleShape)
            .clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center) {
        Text(label, style = Forge.type.headline,
             color = if (enabled) Forge.colors.text else Forge.colors.textTertiary)
    }
}

@Composable
private fun fieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = Forge.colors.surface, unfocusedContainerColor = Forge.colors.surface,
    focusedTextColor = Forge.colors.text, unfocusedTextColor = Forge.colors.text)
