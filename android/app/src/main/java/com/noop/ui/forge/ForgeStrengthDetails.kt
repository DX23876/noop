package com.noop.ui.forge

import com.noop.ui.noopFieldColors

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.noop.R
import com.noop.core.CoreTrainingReports
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Only the form is platform-specific. The shared editor validates ratings and owns the saved row. */
@Composable
internal fun StrengthDetailsPage(session: CoreTrainingReports.GenericSession, muscles: List<String>,
                                 onClose: () -> Unit, onSaved: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var drafts by remember(session.id) { mutableStateOf(session.drafts.ifEmpty { listOf(CoreTrainingReports.EntryDraft()) }) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    BackHandler { if (!saving) onClose() }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_report_add_details), onBack = { if (!saving) onClose() })
        ReportNote("${session.title} · ${sessionDate(session.startTs)}")
        ForgeCard(Modifier.fillMaxWidth()) { ReportNote(stringResource(R.string.forge_report_details_method)) }
        drafts.forEachIndexed { index, draft ->
            ForgeCard(Modifier.fillMaxWidth()) {
                fun update(value: CoreTrainingReports.EntryDraft) { drafts = drafts.toMutableList().also { it[index] = value } }
                OutlinedTextField(draft.title, { update(draft.copy(title = it)) }, enabled = !saving,
                    label = { Text(stringResource(R.string.forge_report_exercise)) }, modifier = Modifier.fillMaxWidth(), colors = noopFieldColors())
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    ReportNote(stringResource(R.string.forge_report_working_sets))
                    TextButton(enabled = !saving && draft.workSets > 1, onClick = { update(draft.copy(workSets = draft.workSets - 1)) }) { Text("−") }
                    Text(draft.workSets.toString(), color = Forge.colors.text)
                    TextButton(enabled = !saving && draft.workSets < 20, onClick = { update(draft.copy(workSets = draft.workSets + 1)) }) { Text("+") }
                }
                ReportNote(stringResource(R.string.forge_report_primary_muscle))
                if (!saving) ReportPicker(hevyMuscleName(draft.muscle), muscles.map { hevyMuscleName(it) }) {
                    update(draft.copy(muscle = muscles[it]))
                } else ReportNote(hevyMuscleName(draft.muscle))
                if (!saving) ForgeSegmented(listOf("RIR", "RPE"), if (draft.usesRIR) 0 else 1, Modifier.fillMaxWidth()) {
                    update(draft.copy(usesRIR = it == 0, effort = ""))
                }
                OutlinedTextField(draft.effort, { update(draft.copy(effort = it)) }, enabled = !saving,
                    label = { Text(stringResource(if (draft.usesRIR) R.string.forge_report_optional_rir else R.string.forge_report_optional_rpe)) },
                    modifier = Modifier.fillMaxWidth(), colors = noopFieldColors())
                TextButton(enabled = !saving && drafts.size > 1,
                    onClick = { drafts = drafts.filterIndexed { i, _ -> i != index } }) { Text(stringResource(R.string.forge_report_remove_exercise)) }
            }
        }
        TextButton(enabled = !saving, onClick = { drafts = drafts + CoreTrainingReports.EntryDraft() }) { Text(stringResource(R.string.forge_report_add_exercise)) }
        error?.let { ReportNote(detailError(it)) }
        Button(enabled = !saving, modifier = Modifier.fillMaxWidth(), onClick = {
            scope.launch {
                saving = true; error = null
                val result = withContext(Dispatchers.IO) {
                    CoreTrainingReports.saveDetails(session.id, drafts, dismissedTrainingWorkouts(context))
                }
                saving = false
                if (result == "saved") onSaved() else error = result
            }
        }) { Text(stringResource(R.string.forge_report_save)) }
        if (saving) LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

@Composable
internal fun StrengthMappingDialog(title: String, muscles: List<String>, onClose: () -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var primary by remember { mutableStateOf("other") }
    var secondary by remember { mutableStateOf(emptySet<String>()) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = { if (!saving) onClose() }, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            ReportNote(stringResource(R.string.forge_report_primary_muscle))
            if (!saving) ReportPicker(hevyMuscleName(primary), muscles.map { hevyMuscleName(it) }) {
                primary = muscles[it]; secondary = secondary - primary
            } else ReportNote(hevyMuscleName(primary))
            ReportNote(stringResource(R.string.forge_report_secondary_muscles))
            muscles.filter { it != primary && it != "other" }.forEach { muscle ->
                Row(Modifier.fillMaxWidth().clickable(enabled = !saving) {
                    secondary = if (muscle in secondary) secondary - muscle else secondary + muscle
                }, verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(muscle in secondary, onCheckedChange = null, enabled = !saving)
                    ReportNote(hevyMuscleName(muscle))
                }
            }
            if (failed) ReportNote(stringResource(R.string.forge_report_save_failed))
        }
    }, confirmButton = {
        TextButton(enabled = !saving && primary != "other", onClick = {
            scope.launch {
                saving = true; failed = false
                val saved = withContext(Dispatchers.IO) { CoreTrainingReports.mapExercise(title, primary, secondary.toList()) }
                saving = false
                if (saved) onSaved() else failed = true
            }
        }) { Text(stringResource(R.string.forge_report_save)) }
    }, dismissButton = { TextButton(enabled = !saving, onClick = onClose) { Text(stringResource(R.string.forge_report_cancel)) } })
}

@Composable
internal fun MuscleFeedbackDialog(muscle: String, onClose: () -> Unit, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var feeling by remember { mutableIntStateOf(0) }
    var saving by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    val labels = listOf(R.string.forge_report_fresh, R.string.forge_report_a_bit_tired,
        R.string.forge_report_tired, R.string.forge_report_wrecked)
    AlertDialog(onDismissRequest = { if (!saving) onClose() }, title = { Text(hevyMuscleName(muscle)) }, text = {
        Column {
            ReportNote(stringResource(R.string.forge_report_feedback_method))
            labels.forEachIndexed { index, label ->
                Row(Modifier.fillMaxWidth().clickable(enabled = !saving) { feeling = index }, verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(feeling == index, onClick = null, enabled = !saving)
                    ReportNote(stringResource(label))
                }
            }
            if (failed) ReportNote(stringResource(R.string.forge_report_save_failed))
        }
    }, confirmButton = {
        TextButton(enabled = !saving, onClick = {
            scope.launch {
                saving = true; failed = false
                val saved = withContext(Dispatchers.IO) { CoreTrainingReports.recordFeedback(muscle, feeling) }
                saving = false
                if (saved) onSaved() else failed = true
            }
        }) { Text(stringResource(R.string.forge_report_save)) }
    }, dismissButton = { TextButton(enabled = !saving, onClick = onClose) { Text(stringResource(R.string.forge_report_cancel)) } })
}

@Composable
private fun detailError(error: String) = stringResource(when (error) {
    "noExercise" -> R.string.forge_report_no_exercise
    "invalidEffort" -> R.string.forge_report_invalid_effort
    "invalidSets" -> R.string.forge_report_invalid_sets
    "sessionUnavailable" -> R.string.forge_report_session_unavailable
    else -> R.string.forge_report_save_failed
})

/** Hevy group labels remain storage keys in the core; names are localized at the platform edge. */
@Composable
internal fun hevyMuscleName(id: String): String = when (id) {
    "shoulders" -> stringResource(R.string.forge_report_shoulders)
    "full_body" -> stringResource(R.string.forge_report_full_body)
    "cardio" -> stringResource(R.string.forge_tl_cardio)
    "other" -> stringResource(R.string.forge_report_other)
    "shins" -> muscleName("tibialis")
    else -> muscleName(id)
}
@Composable
internal fun balanceNames(axis: String): String = stringResource(when (axis) {
    "pushPull" -> R.string.forge_report_push_pull
    "upperLower" -> R.string.forge_report_upper_lower
    else -> R.string.forge_report_quads_posterior
})
@Composable
internal fun distanceBandName(band: String): String = stringResource(when (band) {
    "short" -> R.string.forge_report_short
    "medium" -> R.string.forge_report_medium
    "long" -> R.string.forge_report_long
    else -> R.string.forge_report_very_long
})
@Composable
internal fun familyName(family: String): String = stringResource(when (family) {
    "endurance" -> R.string.forge_report_endurance
    "conditioning" -> R.string.forge_report_conditioning
    else -> R.string.forge_report_other
})
@Composable
internal fun repBandName(band: String): String = stringResource(R.string.forge_report_reps, when (band) {
    "oneToThree" -> "1–3"; "fourToSix" -> "4–6"; "sevenToTwelve" -> "7–12"; else -> "13+"
})
@Composable
internal fun setTypeName(type: String): String = stringResource(when (type) {
    "warmup" -> R.string.forge_report_warmup
    "dropset" -> R.string.forge_report_dropset
    "failure" -> R.string.forge_report_failure
    "rest_pause" -> R.string.forge_report_rest_pause
    "amrap" -> R.string.forge_report_amrap
    "normal" -> R.string.forge_report_work_set
    else -> R.string.forge_report_other
})
@Composable
internal fun strengthSource(source: String): String = when (source) {
    "noop_native" -> "NOOP"
    "hevy_api", "hevy_csv" -> "Hevy"
    "manual" -> stringResource(R.string.forge_report_manual)
    else -> source
}
