package com.noop.ui.forge

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CorePrefs
import com.noop.core.CoreTrainingReminders
import com.noop.notif.SessionRatingReminderWorker
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.format.TextStyle
import java.util.Locale

/**
 * Fork (DX23876), Android parity plan 2.3: Settings › Goals as iOS has it (`GoalsSettingsView`): how many goals,
 * the rest days, the daily step goal, the goal notifications and the motivation switch. The values live in the
 * shared core's settings ([CorePrefs]), where goals and Momentum read them, as Apple's UserDefaults do.
 */
@Composable
internal fun GoalsSettingsSection(viewModel: com.noop.ui.AppViewModel) {
    val context = LocalContext.current
    val stored = remember { CorePrefs.read(context) }
    var longTerm by remember { mutableStateOf(stored.optInt(CorePrefs.LONG_TERM_LIMIT, 5)) }
    var period by remember { mutableStateOf(stored.optInt(CorePrefs.PERIOD_LIMIT, 6)) }
    var stepGoal by remember { mutableStateOf(stored.optInt(CorePrefs.STEP_GOAL, 0)) }
    var motivation by remember { mutableStateOf(stored.optBoolean(CorePrefs.MOTIVATION, true)) }
    var invite by remember { mutableStateOf(!stored.optBoolean(CorePrefs.INVITE_DISMISSED, false)) }
    val streaks by viewModel.streaks.collectAsState()
    var restDays by remember {
        mutableStateOf(stored.optJSONArray(CorePrefs.REST_WEEKDAYS)?.let { a -> (0 until a.length()).map(a::getInt).toSet() }
                           ?: emptySet())
    }
    fun save(key: String, value: Any) = CorePrefs.write(context, key, value)

    Text(stringResource(R.string.forge_sg_goals_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
    SettingsCard(stringResource(R.string.forge_sg_how_many), null) {
        SettingRow(stringResource(R.string.forge_sg_long_term_limit, longTerm)) {
            Stepper("", onMinus = { if (longTerm > 1 && save(CorePrefs.LONG_TERM_LIMIT, longTerm - 1)) longTerm-- },
                    onPlus = { if (longTerm < 10 && save(CorePrefs.LONG_TERM_LIMIT, longTerm + 1)) longTerm++ })
        }
        RowDivider()
        SettingRow(stringResource(R.string.forge_sg_period_limit, period)) {
            Stepper("", onMinus = { if (period > 1 && save(CorePrefs.PERIOD_LIMIT, period - 1)) period-- },
                    onPlus = { if (period < 12 && save(CorePrefs.PERIOD_LIMIT, period + 1)) period++ })
        }
        Note(stringResource(R.string.forge_sg_limit_note))
    }
    SettingsCard(stringResource(R.string.forge_sg_rest_days), null) {
        RestDaysPicker(context, restDays) { days -> if (save(CorePrefs.REST_WEEKDAYS, days.sorted())) restDays = days }
        Note(stringResource(R.string.forge_sg_rest_days_note))
    }
    SettingsCard(stringResource(R.string.forge_sg_step_goal), null) {
        SettingRow(if (stepGoal > 0) stringResource(R.string.forge_sg_steps, stepGoal) else stringResource(R.string.forge_sg_not_set)) {
            Stepper("", onMinus = { val v = (stepGoal - 500).coerceAtLeast(0); if (save(CorePrefs.STEP_GOAL, v)) stepGoal = v },
                    onPlus = { val v = (stepGoal + 500).coerceAtMost(30_000); if (save(CorePrefs.STEP_GOAL, v)) stepGoal = v })
        }
        Note(stringResource(R.string.forge_sg_step_goal_note))
    }
    GoalNotificationsCard()
    SettingsCard(stringResource(R.string.forge_sg_motivation), null) {
        ToggleRow(stringResource(R.string.forge_sg_motivation_switch), stringResource(R.string.forge_sg_motivation_note),
                  motivation) { on -> if (save(CorePrefs.MOTIVATION, on)) motivation = on }
        RowDivider()
        // Day streak (#569): consecutive days with a Charge score, beside the switch as on iOS.
        SettingRow(stringResource(R.string.forge_sg_streak)) {
            Text(if (streaks.current == 1) stringResource(R.string.forge_sg_streak_one)
                 else stringResource(R.string.forge_sg_streak_n, streaks.current),
                 style = Forge.type.footnote, color = Forge.colors.accent)
        }
        Note(if (streaks.longest == 1) stringResource(R.string.forge_sg_longest_one)
             else stringResource(R.string.forge_sg_longest_n, streaks.longest))
    }
    SettingsCard(null, null) {
        ToggleRow(stringResource(R.string.forge_sg_invite), null, invite) { on ->
            if (save(CorePrefs.INVITE_DISMISSED, !on)) invite = on
        }
        RowDivider()
        LinkRow(stringResource(R.string.forge_sg_explainer), null) {
            // The goals page shows the explainer again the next time it opens.
            save(CorePrefs.INTRO_SEEN, false)
        }
    }
}

/** The seven weekdays as round toggles (iOS `RestDaysPicker`), in the week order set under Language & Units. */
@Composable
private fun RestDaysPicker(context: Context, selected: Set<Int>, onChange: (Set<Int>) -> Unit) {
    val sundayFirst = NoopPrefs.of(context).getString("training.weekStartsOn", null) == "sunday"
    // Calendar weekday numbers as Apple stores them: 1 = Sunday … 7 = Saturday.
    val order = if (sundayFirst) listOf(1, 2, 3, 4, 5, 6, 7) else listOf(2, 3, 4, 5, 6, 7, 1)
    val colors = Forge.colors
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        order.forEach { weekday ->
            val day = DayOfWeek.of(if (weekday == 1) 7 else weekday - 1)
            val on = weekday in selected
            Box(Modifier.size(40.dp).background(if (on) colors.accent else colors.inset, CircleShape)
                    .clickable(role = Role.Checkbox) { onChange(if (on) selected - weekday else selected + weekday) },
                contentAlignment = Alignment.Center) {
                Text(day.getDisplayName(TextStyle.NARROW, Locale.getDefault()), style = Forge.type.footnote,
                     color = if (on) androidx.compose.ui.graphics.Color.White else colors.text)
            }
        }
    }
}

@Composable
private fun Note(text: String) = Text(text, style = Forge.type.caption, color = Forge.colors.textTertiary)

/**
 * Fork (DX23876), Android parity plan 2.3: Settings › Training as iOS has it (`trainingCard`, `guidedTrainingCard`),
 * limited to what Android's training uses: the session rating reminder, the weight unit, a new exercise's sets and
 * rest, per-set effort, the rest timer, the exercise media and workout suggestions.
 */
@Composable
internal fun TrainingSettingsSection(onOpenMedia: () -> Unit, onOpenEquipment: () -> Unit, onOpenDonation: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { NoopPrefs.of(context) }
    val stored = remember { CorePrefs.read(context) }
    var rating by remember { mutableStateOf(CoreTrainingReminders.prompt(context)) }
    var effort by remember { mutableStateOf(prefs.getString(CorePrefs.EFFORT_SCALE, null) ?: stored.optString(CorePrefs.EFFORT_SCALE, "rpe")) }
    var unit by remember { mutableStateOf(prefs.getString(CorePrefs.WEIGHT_UNIT, null) ?: stored.optString(CorePrefs.WEIGHT_UNIT, "kilograms")) }
    var sets by remember { mutableStateOf(stored.optInt(CorePrefs.NEW_EXERCISE_SETS, 3)) }
    var rest by remember { mutableStateOf(stored.optInt(CorePrefs.DEFAULT_REST, prefs.getInt(CorePrefs.DEFAULT_REST, 120))) }
    var warmupRest by remember { mutableStateOf(stored.optInt(CorePrefs.WARMUP_REST, 60)) }
    var restPause by remember { mutableStateOf(TrainingStepPrefs.restPauseSeconds(context)) }
    var weightStepKg by remember(unit) { mutableStateOf(TrainingStepPrefs.weightIncrementKg(context)) }
    var guidedTraining by remember { mutableStateOf(com.noop.ui.LiveSessionPrefs.enabled(context)) }
    var feedback by remember { mutableStateOf(RestTimerPrefs.feedback(context)) }
    var doubleTap by remember { mutableStateOf(RestTimerPrefs.strapDoubleTap(context)) }
    var sound by remember { mutableStateOf(RestTimerPrefs.sound(context)) }
    var vibration by remember { mutableStateOf(RestTimerPrefs.haptics(context)) }
    var strapBuzz by remember { mutableStateOf(RestTimerPrefs.strapBuzz(context)) }
    var keepOn by remember { mutableStateOf(RestTimerPrefs.keepScreenOn(context)) }
    var workoutView by remember { mutableStateOf(prefs.getString(WORKOUT_LAYOUT, "list") ?: "list") }
    var media by remember { mutableStateOf(prefs.getString("training.mediaPresentation", "large") ?: "large") }
    var suggestions by remember { mutableStateOf(NoopPrefs.autoDetectWorkouts(context)) }
    val activityPrefs = remember { NoopPrefs.of(context) }
    var walks by remember { mutableStateOf(activityPrefs.getBoolean(com.noop.core.CoreActivity.KEY_WALKS, true)) }
    var level by remember { mutableStateOf(activityPrefs.getString(com.noop.core.CoreActivity.KEY_LEVEL, "balanced") ?: "balanced") }
    var notify by remember { mutableStateOf(activityPrefs.getBoolean(com.noop.core.CoreActivity.KEY_NOTIFY, true)) }

    Text(stringResource(R.string.forge_st_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
    SettingsCard(stringResource(R.string.forge_training), stringResource(R.string.forge_st_blurb)) {
        Overline(stringResource(R.string.forge_st_logging))
        val effortIds = listOf("off", "rir", "rpe")
        val effortLabels = listOf(stringResource(R.string.forge_st_off), "RIR", stringResource(R.string.forge_ef_rpe))
        Text(stringResource(R.string.forge_st_set_effort), style = Forge.type.body, color = Forge.colors.text)
        run {
            ReportPicker(effortLabels[effortIds.indexOf(effort).coerceAtLeast(0)], effortLabels) { i ->
                if (CorePrefs.write(context, CorePrefs.EFFORT_SCALE, effortIds[i])) effort = effortIds[i]
            }
        }
        Note(stringResource(R.string.forge_st_set_effort_note))
        RowDivider()
        val ratingIds = listOf("off", "whenUseful", "always")
        val ratingLabels = listOf(stringResource(R.string.forge_rating_reminder_off),
            stringResource(R.string.forge_rating_reminder_useful), stringResource(R.string.forge_rating_reminder_always))
        Text(stringResource(R.string.forge_st_rating), style = Forge.type.body, color = Forge.colors.text)
        run {
            ReportPicker(ratingLabels[ratingIds.indexOf(rating).coerceAtLeast(0)], ratingLabels) { i ->
                rating = ratingIds[i]
                prefs.edit().putString(CoreTrainingReminders.PREFERENCE, rating).apply()
                scope.launch { withContext(Dispatchers.IO) { SessionRatingReminderWorker.synchronize(context) } }
            }
        }
        Note(stringResource(R.string.forge_st_rating_note))
        RowDivider()
        val unitIds = listOf("kilograms", "pounds")
        val unitLabels = listOf(stringResource(R.string.forge_st_kg), stringResource(R.string.forge_st_lb))
        Text(stringResource(R.string.forge_st_weight_unit), style = Forge.type.body, color = Forge.colors.text)
        run {
            ReportPicker(unitLabels[unitIds.indexOf(unit).coerceAtLeast(0)], unitLabels) { i ->
                if (CorePrefs.write(context, CorePrefs.WEIGHT_UNIT, unitIds[i])) unit = unitIds[i]
            }
        }
        Note(stringResource(R.string.forge_st_weight_unit_note))
        RowDivider()
        // The step of the minus and plus buttons for dumbbells, machines and cables (iOS "Weight step"); a pound
        // wearer picks from pounds, and the choice is stored in kilograms under the key for that unit.
        val pounds = unit == "pounds"
        val system = if (pounds) com.noop.ui.UnitSystem.IMPERIAL else com.noop.ui.UnitSystem.METRIC
        val stepChoices = if (pounds) TrainingStepPrefs.poundChoicesKg else TrainingStepPrefs.kilogramChoices
        val stepLabels = stepChoices.map { TrainingStepPrefs.label(it, system) }
        Text(stringResource(R.string.fsp1_weight_step), style = Forge.type.body, color = Forge.colors.text)
        run {
            val current = stepChoices.indexOfFirst { kotlin.math.abs(it - weightStepKg) < 1e-6 }.coerceAtLeast(0)
            ReportPicker(stepLabels[current], stepLabels) { i ->
                weightStepKg = stepChoices[i]
                TrainingStepPrefs.setWeightIncrementKg(context, stepChoices[i], pounds)
            }
        }
        Note(stringResource(R.string.fsp1_weight_step_note))
        RowDivider()
        SettingRow(stringResource(R.string.forge_st_new_sets, sets)) {
            Stepper("", onMinus = { if (sets > 1 && CorePrefs.write(context, CorePrefs.NEW_EXERCISE_SETS, sets - 1)) sets-- },
                    onPlus = { if (sets < 6 && CorePrefs.write(context, CorePrefs.NEW_EXERCISE_SETS, sets + 1)) sets++ })
        }
        RowDivider()
        Overline(stringResource(R.string.forge_st_rest_times))
        SettingRow(stringResource(R.string.forge_st_default_rest, rest)) {
            Stepper("", onMinus = { val v = (rest - 15).coerceAtLeast(0); if (CorePrefs.write(context, CorePrefs.DEFAULT_REST, v)) rest = v },
                    onPlus = { val v = (rest + 15).coerceAtMost(600); if (CorePrefs.write(context, CorePrefs.DEFAULT_REST, v)) rest = v })
        }
        RowDivider()
        SettingRow(stringResource(R.string.forge_st_warmup_rest, warmupRest)) {
            Stepper("", onMinus = { val v = (warmupRest - 15).coerceAtLeast(0); if (CorePrefs.write(context, CorePrefs.WARMUP_REST, v)) warmupRest = v },
                    onPlus = { val v = (warmupRest + 15).coerceAtMost(300); if (CorePrefs.write(context, CorePrefs.WARMUP_REST, v)) warmupRest = v })
        }
        RowDivider()
        SettingRow(stringResource(R.string.fsp1_rest_pause, restPause)) {
            Stepper("", onMinus = { val v = (restPause - 5).coerceAtLeast(5); restPause = v; TrainingStepPrefs.setRestPauseSeconds(context, v) },
                    onPlus = { val v = (restPause + 5).coerceAtMost(60); restPause = v; TrainingStepPrefs.setRestPauseSeconds(context, v) })
        }
        RowDivider()
        Overline(stringResource(R.string.forge_st_timer_ends))
        ToggleRow(stringResource(R.string.forge_st_show_notification), null, feedback) {
            feedback = it; prefs.edit().putBoolean(RestTimerPrefs.FEEDBACK, it).apply()
        }
        ToggleRow(stringResource(R.string.forge_st_sound), null, sound, enabled = feedback) {
            sound = it; prefs.edit().putBoolean(RestTimerPrefs.SOUND, it).apply()
        }
        ToggleRow(stringResource(R.string.forge_st_vibration), null, vibration) { vibration = it; prefs.edit().putBoolean(RestTimerPrefs.HAPTICS, it).apply() }
        ToggleRow(stringResource(R.string.forge_st_strap_buzz), null, strapBuzz) { strapBuzz = it; RestTimerPrefs.setStrapBuzz(context, it) }
        Note(stringResource(R.string.forge_st_timer_note))
        RowDivider()
        Overline(stringResource(R.string.forge_st_strap))
        ToggleRow(stringResource(R.string.forge_tap_setting), stringResource(R.string.forge_tap_setting_note), doubleTap) {
            doubleTap = it; prefs.edit().putBoolean(RestTimerPrefs.STRAP_DOUBLE_TAP, it).apply()
        }
        RowDivider()
        ToggleRow(stringResource(R.string.forge_st_keep_screen), stringResource(R.string.forge_st_keep_screen_note), keepOn) {
            keepOn = it; prefs.edit().putBoolean(RestTimerPrefs.KEEP_SCREEN_ON, it).apply()
        }
        RowDivider()
        Overline(stringResource(R.string.forge_st_during))
        val viewIds = listOf("focus", "list", "compact")
        val viewLabels = listOf(stringResource(R.string.forge_wl_focus_short), stringResource(R.string.forge_wl_list_short),
                                stringResource(R.string.forge_wl_compact))
        Text(stringResource(R.string.forge_wl_view), style = Forge.type.body, color = Forge.colors.text)
        run {
            ReportPicker(viewLabels[viewIds.indexOf(workoutView).coerceAtLeast(0)], viewLabels) { i ->
                workoutView = viewIds[i]
                prefs.edit().putString(WORKOUT_LAYOUT, workoutView).apply()
            }
        }
        RowDivider()
        val mediaIds = listOf("large", "small", "hidden")
        val mediaLabels = listOf(stringResource(R.string.forge_st_media_large), stringResource(R.string.forge_st_media_small),
                                 stringResource(R.string.forge_st_media_hidden))
        Text(stringResource(R.string.forge_st_media), style = Forge.type.body, color = Forge.colors.text)
        run {
            ReportPicker(mediaLabels[mediaIds.indexOf(media).coerceAtLeast(0)], mediaLabels) { i ->
                media = mediaIds[i]
                prefs.edit().putString("training.mediaPresentation", media).apply()
            }
        }
        RowDivider()
        LinkRow(stringResource(R.string.forge_st_manage_media), null, onClick = onOpenMedia)
        RowDivider()
        LinkRow(stringResource(R.string.fsp1_equipment_title), null, onClick = onOpenEquipment)
        RowDivider()
        Note(stringResource(R.string.forge_st_units_note))
    }
    SettingsCard(stringResource(R.string.forge_st_guided), stringResource(R.string.forge_st_guided_blurb)) {
        // Live Sessions (beta): the start button on Today, in the coach and in More (iOS "Guided training").
        ToggleRow(stringResource(R.string.fsp1_guided_switch), stringResource(R.string.fsp1_guided_note), guidedTraining) { on ->
            guidedTraining = on
            com.noop.ui.LiveSessionPrefs.setEnabled(context, on)
        }
        RowDivider()
        ToggleRow(stringResource(R.string.forge_st_suggestions), stringResource(R.string.forge_st_suggestions_note),
                  suggestions) { on ->
            suggestions = on
            NoopPrefs.setAutoDetectWorkouts(context, on)
            scope.launch(Dispatchers.IO) { ActivitySuggestionState.reload(context) }
        }
        RowDivider()
        // The donation page, reached from the sport settings because that is where the ticks apply. Named for what
        // it does for the wearer, not for the data it moves.
        LinkRow(stringResource(R.string.fsp1_help_teach), stringResource(R.string.fsp1_help_teach_note), onClick = onOpenDonation)
        if (suggestions) {
            // Activity detection's own choices (decision 2026-10-31); a WHOOP 4.0 counts no steps.
            val noSteps = remember { activeStrapCountsNoSteps(context) }
            RowDivider()
            ToggleRow(stringResource(R.string.forge_st_detect_walks),
                      if (noSteps) stringResource(R.string.forge_st_no_steps) else null,
                      walks && !noSteps) { on ->
                if (!noSteps) {
                    walks = on
                    activityPrefs.edit().putBoolean(com.noop.core.CoreActivity.KEY_WALKS, on).apply()
                }
            }
            RowDivider()
            val levelIds = listOf("more", "balanced", "onlyClear")
            val levelLabels = listOf(stringResource(R.string.forge_st_level_more),
                stringResource(R.string.forge_st_level_balanced), stringResource(R.string.forge_st_level_clear))
            Text(stringResource(R.string.forge_st_ask_level), style = Forge.type.body, color = Forge.colors.text)
            ReportPicker(levelLabels[levelIds.indexOf(level).coerceAtLeast(0)], levelLabels) { i ->
                level = levelIds[i]
                activityPrefs.edit().putString(com.noop.core.CoreActivity.KEY_LEVEL, level).apply()
            }
            RowDivider()
            ToggleRow(stringResource(R.string.forge_st_notify), stringResource(R.string.forge_st_notify_note), notify) { on ->
                notify = on
                activityPrefs.edit().putBoolean(com.noop.core.CoreActivity.KEY_NOTIFY, on).apply()
            }
        }
    }
}

@Composable
private fun Overline(text: String) =
    Text(text.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary)

/**
 * The training steps Settings sets and the plan builder and the timers read: the step of a weight button (kilograms and
 * pounds each keep their own, as on Apple, both stored in kilograms) and the rest after a rest-pause set. Plain
 * preferences, since no core call reads them.
 */
internal object TrainingStepPrefs {
    const val WEIGHT_STEP_KG = "training.weightIncrementKg"
    const val WEIGHT_STEP_LB = "training.weightIncrementLbKg"
    const val REST_PAUSE = "training.restPauseSeconds"
    private const val DEFAULT_REST_PAUSE = 20

    /** The steps offered for kilograms, and for pounds (1, 2.5, 5 and 10 lb) in kilograms. */
    val kilogramChoices = listOf(0.5, 1.0, 1.25, 2.0, 2.5, 5.0)
    val poundChoicesKg = listOf(1.0, 2.5, 5.0, 10.0).map { it / com.noop.ui.UnitFormatter.POUNDS_PER_KILOGRAM }

    /** The step in force for the weight unit chosen under Training, in kilograms: 2.5 kg, or 5 lb, until one is picked. */
    fun weightIncrementKg(context: Context): Double {
        val prefs = NoopPrefs.of(context)
        val pounds = prefs.getString(CorePrefs.WEIGHT_UNIT, null) == "pounds"
        val stored = prefs.getString(if (pounds) WEIGHT_STEP_LB else WEIGHT_STEP_KG, null)?.toDoubleOrNull()?.takeIf { it > 0 }
        return stored ?: if (pounds) 5.0 / com.noop.ui.UnitFormatter.POUNDS_PER_KILOGRAM else 2.5
    }

    fun setWeightIncrementKg(context: Context, kilograms: Double, pounds: Boolean) {
        NoopPrefs.of(context).edit().putString(if (pounds) WEIGHT_STEP_LB else WEIGHT_STEP_KG, kilograms.toString()).apply()
    }

    fun restPauseSeconds(context: Context): Int =
        NoopPrefs.of(context).getInt(REST_PAUSE, DEFAULT_REST_PAUSE).takeIf { it > 0 } ?: DEFAULT_REST_PAUSE

    fun setRestPauseSeconds(context: Context, seconds: Int) {
        NoopPrefs.of(context).edit().putInt(REST_PAUSE, seconds.coerceIn(5, 60)).apply()
    }

    /** A step as the picker shows it: the figure in the unit's own numbers, half a pound at the finest ("2.5 kg", "5 lb"). */
    fun label(kilograms: Double, system: com.noop.ui.UnitSystem): String {
        val shown = if (system == com.noop.ui.UnitSystem.IMPERIAL) com.noop.ui.UnitFormatter.kgToPounds(kilograms) else kilograms
        val format = java.text.NumberFormat.getNumberInstance(Locale.getDefault()).apply {
            maximumFractionDigits = if (system == com.noop.ui.UnitSystem.IMPERIAL) 1 else 2
        }
        return "${format.format(shown)} ${com.noop.ui.UnitFormatter.massUnit(system)}"
    }
}
