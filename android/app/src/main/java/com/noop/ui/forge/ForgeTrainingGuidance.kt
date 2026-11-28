package com.noop.ui.forge

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.width
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreTrainingGuidance
import com.noop.core.TrainingGuidancePrefs
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.launch

// Training Load phase 2 on Android (docs/fork/TRAINING_LOAD_PLAN.md §8): the same advice card, "enough?" card, Lab
// card and settings the iPhone shows, drawn from the core's `training.guidance` snapshot. Nothing is decided here.

@Composable
internal fun stanceTitle(stance: String): String = when (stance) {
    "push" -> stringResource(R.string.forge_tg_push)
    "easy" -> stringResource(R.string.forge_tg_easy)
    "rest" -> stringResource(R.string.forge_tg_rest)
    else -> stringResource(R.string.forge_tg_steady)
}

@Composable
internal fun adviceReason(a: CoreTrainingGuidance.Advice): String {
    if (a.state == "waitingForNight") return stringResource(R.string.forge_tg_reason_waiting)
    return stringResource(when (a.reason) {
        "illness" -> R.string.forge_tg_reason_illness
        "strainedRecovery" -> R.string.forge_tg_reason_strained
        "lowCharge" -> R.string.forge_tg_reason_low_charge
        "strengthWellAbove" -> R.string.forge_tg_reason_strength_high
        "cardioWellAbove" -> R.string.forge_tg_reason_cardio_high
        "bothWellAbove" -> R.string.forge_tg_reason_both_high
        "planned" -> R.string.forge_tg_reason_planned
        "plannedShorter" -> R.string.forge_tg_reason_planned_shorter
        "behindGoal" -> R.string.forge_tg_reason_behind
        "noNight" -> R.string.forge_tg_reason_no_night
        else -> R.string.forge_tg_reason_steady
    })
}

@Composable
private fun offerText(o: CoreTrainingGuidance.Offer): String = when (o.kind) {
    "planned" -> o.title.orEmpty()
    "cardio" -> stringResource(R.string.forge_tg_offer_cardio, o.minutes ?: 0, o.sport.orEmpty())
    "strength" -> stringResource(R.string.forge_tg_offer_strength, o.sets ?: 0, muscleName(o.group.orEmpty()))
    "startWalk" -> stringResource(R.string.forge_tg_offer_walk, o.minutes ?: 30)
    else -> stringResource(R.string.forge_tg_offer_easy)
}

/** Today's advice: the stance, its reason, the offers and the session waiting for a rating. */
@Composable
internal fun ForgeAdviceCard(guidance: CoreTrainingGuidance.Snapshot, showOffers: Boolean = true,
                             showPlanned: Boolean = true) {
    val colors = Forge.colors
    val a = guidance.advice
    ForgeCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.forge_tg_overline), style = Forge.type.footnote, color = colors.textSecondary)
            Text(stanceTitle(a.stance), style = Forge.type.subhead, color = colors.text)
            Text(adviceReason(a), style = Forge.type.body, color = colors.text)
            if (a.state == "done") Text(stringResource(R.string.forge_tg_done), style = Forge.type.footnote, color = colors.textSecondary)
            if (a.ateTooLittle) Text(stringResource(R.string.forge_tg_ate_too_little), style = Forge.type.footnote, color = colors.textSecondary)
            if (showOffers) guidance.offers.filter { showPlanned || it.kind != "planned" }.forEach { o ->
                Text("•  " + offerText(o), style = Forge.type.body, color = colors.text)
            }
            // A planned session against the advice, moved to tomorrow only on a tap (Q17, Q27).
            guidance.movablePlan?.let { m ->
                val moveScope = androidx.compose.runtime.rememberCoroutineScope()
                Text(stringResource(R.string.forge_tg_easier_fits, m.title), style = Forge.type.footnote, color = colors.textSecondary)
                TextButton(onClick = {
                    moveScope.launch {
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { CoreTrainingGuidance.moveToTomorrow(m) }
                        com.noop.core.CoreShadow.noteDataChanged()
                    }
                }) { Text(stringResource(R.string.forge_tg_move_tomorrow)) }
            }
            // Yesterday's or today's session without a rating, rated here in one tap (Q12).
            val ask = guidance.askRating
            if (ask != null) {
                val context = LocalContext.current
                val scope = androidx.compose.runtime.rememberCoroutineScope()
                var rated by remember(ask.sessionId) { mutableStateOf(false) }
                if (!rated) {
                    Text(stringResource(R.string.forge_tg_rate, ask.sport), style = Forge.type.footnote, color = colors.textSecondary)
                    Row(Modifier.horizontalScroll(androidx.compose.foundation.rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                        (1..10).forEach { value ->
                            TextButton(onClick = {
                                rated = true
                                scope.launch {
                                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                                        com.noop.core.CoreTrainingSession.rate(ask.sessionId, value.toDouble(), false,
                                                                               dismissedTrainingWorkouts(context))
                                    }
                                    com.noop.core.CoreShadow.noteDataChanged()
                                }
                            }) { Text(value.toString()) }
                        }
                    }
                }
            }
        }
    }
}

/** "Enough this week?" against the focus target. */
@Composable
internal fun ForgeEnoughCard(guidance: CoreTrainingGuidance.Snapshot) {
    val week = guidance.thisWeek ?: return
    val colors = Forge.colors
    ForgeCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.forge_tg_enough_title), style = Forge.type.subhead, color = colors.text)
            LinearProgressIndicator(progress = { (week.minutes.toFloat() / maxOf(1, week.targetLow)).coerceIn(0f, 1f) },
                                    modifier = Modifier.fillMaxWidth())
            Text(stringResource(R.string.forge_tg_minutes, week.minutes, week.targetLow), style = Forge.type.body, color = colors.text)
            Text(stringResource(R.string.forge_tg_strength_days, week.strengthDays, week.strengthDaysLow),
                 style = Forge.type.body, color = colors.text)
            if (week.everydayMinutes > 0) Text(stringResource(R.string.forge_tg_everyday, week.everydayMinutes),
                                               style = Forge.type.footnote, color = colors.textSecondary)
            if (week.ratedMinutes > 0) Text(stringResource(R.string.forge_tg_rated, week.ratedMinutes),
                                            style = Forge.type.footnote, color = colors.textSecondary)
            if (guidance.carried) Text(stringResource(R.string.forge_tg_carried), style = Forge.type.footnote, color = colors.textSecondary)
            if (week.balanceHint) Text(stringResource(R.string.forge_tg_balance), style = Forge.type.footnote, color = colors.textSecondary)
            Text(stringResource(R.string.forge_tg_enough_caption), style = Forge.type.footnote, color = colors.textSecondary)
        }
    }
}

/** A lane's goal note, as the iPhone's `TrainingGuidanceText.note`. */
@Composable
internal fun goalNoteText(note: String): String = stringResource(when (note) {
    "carriesWeightLoss" -> R.string.forge_tg_note_weight_loss
    "strengthHeld" -> R.string.forge_tg_note_strength_held
    "meetsGuideline" -> R.string.forge_tg_note_guideline
    "goalTooNew" -> R.string.forge_tg_note_new
    "paused" -> R.string.forge_tg_note_paused
    else -> R.string.forge_tg_note_check
})

/** Each lane's verdict after the goal has spoken, with the food log's explanation (Q37, Q40). */
@Composable
internal fun ForgeGoalNotesCard(goals: CoreTrainingGuidance.GoalReadings) {
    val colors = Forge.colors
    val lines = buildList {
        goals.strength.note?.let { add(stringResource(R.string.forge_tg_lane_strength) + ": " + goalNoteText(it)) }
        goals.cardio.note?.let { add(stringResource(R.string.forge_tg_lane_cardio) + ": " + goalNoteText(it)) }
        if (goals.food.ateOverPlan) add(stringResource(R.string.forge_tg_ate_over_plan))
        if (goals.proteinHint) add(stringResource(R.string.forge_tg_protein_low))
    }
    if (lines.isEmpty()) return
    ForgeCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            lines.forEach { Text(it, style = Forge.type.body, color = colors.text) }
        }
    }
}

/** The Lab markers: what each reads and how far its check has come. Never a verdict. */
@Composable
internal fun ForgeInstrumentsCard(instruments: CoreTrainingGuidance.Instruments?) {
    val colors = Forge.colors
    ForgeCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(stringResource(R.string.forge_tg_lab_title), style = Forge.type.subhead, color = colors.text)
            if (instruments == null) return@Column
            listOf(R.string.forge_tg_i_cadence to instruments.cadence, R.string.forge_tg_i_recovery to instruments.recovery,
                   R.string.forge_tg_i_pace to instruments.pace).forEach { (title, i) ->
                Text(stringResource(title), style = Forge.type.body, color = colors.text)
                Text(stringResource(when (i.direction) {
                    "improving" -> R.string.forge_tg_d_better
                    "worsening" -> R.string.forge_tg_d_worse
                    "unclear" -> R.string.forge_tg_d_unclear
                    else -> R.string.forge_tg_d_unknown
                }), style = Forge.type.footnote, color = colors.textSecondary)
                Text(if (i.passes) stringResource(R.string.forge_tg_check_passed)
                     else stringResource(R.string.forge_tg_check_progress, i.pairs ?: 0),
                     style = Forge.type.footnote, color = colors.textSecondary)
            }
            Text(stringResource(R.string.forge_tg_everyday_fitness), style = Forge.type.footnote, color = colors.textSecondary)
        }
    }
}

/** Focus, the pulse that does not show effort, the morning advice and the Lab markers (Q3, Q7, Q16, Q19). */
@Composable
internal fun ForgeGuidanceSettings(onChanged: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { NoopPrefs.of(context) }
    val colors = Forge.colors
    var focus by remember { mutableStateOf(prefs.getString(TrainingGuidancePrefs.FOCUS, "") ?: "") }
    var pulse by remember { mutableStateOf(prefs.getBoolean(TrainingGuidancePrefs.PULSE_UNRELIABLE, false)) }
    var morning by remember { mutableStateOf(prefs.getBoolean(TrainingGuidancePrefs.MORNING_ADVICE, false)) }
    var lab by remember { mutableStateOf(prefs.getBoolean(TrainingGuidancePrefs.LAB_INSTRUMENTS, false)) }
    val focusOptions = listOf("" to R.string.forge_tg_focus_auto, "loseWeight" to R.string.forge_tg_focus_lose,
                              "fitness" to R.string.forge_tg_focus_fitness, "strength" to R.string.forge_tg_focus_strength,
                              "health" to R.string.forge_tg_focus_health)
    ForgeCard(modifier = Modifier.fillMaxWidth()) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(stringResource(R.string.forge_tg_focus_title), style = Forge.type.subhead, color = colors.text)
            focusOptions.forEach { (raw, label) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    androidx.compose.material3.RadioButton(selected = focus == raw, onClick = {
                        focus = raw; prefs.edit().putString(TrainingGuidancePrefs.FOCUS, raw).apply(); onChanged()
                    })
                    Text(stringResource(label), style = Forge.type.body, color = colors.text)
                }
            }
            Text(stringResource(R.string.forge_tg_focus_caption), style = Forge.type.footnote, color = colors.textSecondary)
            SettingSwitch(stringResource(R.string.forge_tg_pulse_title), stringResource(R.string.forge_tg_pulse_caption), pulse) {
                pulse = it; prefs.edit().putBoolean(TrainingGuidancePrefs.PULSE_UNRELIABLE, it).apply(); onChanged()
            }
            SettingSwitch(stringResource(R.string.forge_tg_morning_title), stringResource(R.string.forge_tg_morning_caption), morning) {
                morning = it; prefs.edit().putBoolean(TrainingGuidancePrefs.MORNING_ADVICE, it).apply()
            }
            SettingSwitch(stringResource(R.string.forge_tg_lab_title), stringResource(R.string.forge_tg_lab_caption), lab) {
                lab = it; prefs.edit().putBoolean(TrainingGuidancePrefs.LAB_INSTRUMENTS, it).apply(); onChanged()
            }
        }
    }
}

@Composable
private fun SettingSwitch(title: String, caption: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    val colors = Forge.colors
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            Switch(checked = checked, onCheckedChange = onChange)
        }
        Text(caption, style = Forge.type.footnote, color = colors.textSecondary)
    }
}

/** The guidance snapshot, read once per change of the core's data for the whole app (`TrainingGuidanceHolder`). */
@Composable
internal fun rememberTrainingGuidance(extraKey: Int = 0): CoreTrainingGuidance.Snapshot? {
    val context = LocalContext.current
    val revision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    LaunchedEffect(revision, extraKey) {
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
            com.noop.core.CoreRead.open(context)
            val profile = com.noop.ui.ProfileStore.from(context)
            com.noop.core.TrainingGuidanceHolder.ensure(context, revision, extraKey, profile.hrMax.toDouble(), profile.sex,
                                                        dismissedTrainingWorkouts(context))
        }
    }
    val snapshot by com.noop.core.TrainingGuidanceHolder.snapshot.collectAsState()
    return snapshot
}

/** Today's Effort target: Charge's band capped by the morning advice (Q14), as the iPhone's ring shows it. */
@Composable
internal fun todayEffortTarget(charge: Double?): ClosedFloatingPointRange<Double>? {
    val advice = rememberTrainingGuidance()?.advice
    val low = advice?.effortLow
    val high = advice?.effortHigh
    return if (low != null && high != null) low..high else effortTargetStored(charge)
}
