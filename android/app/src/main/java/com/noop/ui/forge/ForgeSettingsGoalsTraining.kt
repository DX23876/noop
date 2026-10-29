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
internal fun GoalsSettingsSection() {
    val context = LocalContext.current
    val stored = remember { CorePrefs.read(context) }
    var longTerm by remember { mutableStateOf(stored.optInt(CorePrefs.LONG_TERM_LIMIT, 5)) }
    var period by remember { mutableStateOf(stored.optInt(CorePrefs.PERIOD_LIMIT, 6)) }
    var stepGoal by remember { mutableStateOf(stored.optInt(CorePrefs.STEP_GOAL, 0)) }
    var motivation by remember { mutableStateOf(stored.optBoolean(CorePrefs.MOTIVATION, true)) }
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
 * rest, the exercise media and workout suggestions. iOS's rest-timer, strap and workout-screen options belong to its
 * live strength session, which Android does not have yet.
 */
@Composable
internal fun TrainingSettingsSection(onOpenMedia: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val prefs = remember { NoopPrefs.of(context) }
    val stored = remember { CorePrefs.read(context) }
    var rating by remember { mutableStateOf(CoreTrainingReminders.prompt(context)) }
    var unit by remember { mutableStateOf(prefs.getString(CorePrefs.WEIGHT_UNIT, null) ?: stored.optString(CorePrefs.WEIGHT_UNIT, "kilograms")) }
    var sets by remember { mutableStateOf(stored.optInt(CorePrefs.NEW_EXERCISE_SETS, 3)) }
    var rest by remember { mutableStateOf(stored.optInt(CorePrefs.DEFAULT_REST, prefs.getInt(CorePrefs.DEFAULT_REST, 120))) }
    var media by remember { mutableStateOf(prefs.getString("training.mediaPresentation", "large") ?: "large") }
    var suggestions by remember { mutableStateOf(NoopPrefs.autoDetectWorkouts(context)) }

    Text(stringResource(R.string.forge_st_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
    SettingsCard(stringResource(R.string.forge_training), stringResource(R.string.forge_st_blurb)) {
        Overline(stringResource(R.string.forge_st_logging))
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
        Overline(stringResource(R.string.forge_st_during))
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
        LinkRow(stringResource(R.string.forge_st_manage_media), null, onOpenMedia)
        RowDivider()
        Note(stringResource(R.string.forge_st_units_note))
    }
    SettingsCard(stringResource(R.string.forge_st_guided), stringResource(R.string.forge_st_guided_blurb)) {
        ToggleRow(stringResource(R.string.forge_st_suggestions), stringResource(R.string.forge_st_suggestions_note),
                  suggestions) { on ->
            suggestions = on
            NoopPrefs.setAutoDetectWorkouts(context, on)
        }
    }
}

@Composable
private fun Overline(text: String) =
    Text(text.uppercase(), style = Forge.type.overline, color = Forge.colors.textSecondary)
