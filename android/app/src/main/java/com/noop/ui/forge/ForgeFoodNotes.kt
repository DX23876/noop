package com.noop.ui.forge

import kotlinx.coroutines.launch
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.WineBar
import androidx.compose.material.icons.rounded.Cake
import androidx.compose.material.icons.rounded.LunchDining
import androidx.compose.material.icons.rounded.Grain
import androidx.compose.material.icons.rounded.Opacity
import androidx.compose.material.icons.rounded.SetMeal
import androidx.compose.material.icons.rounded.OutdoorGrill
import androidx.compose.material.icons.rounded.Grass
import androidx.compose.material.icons.rounded.LocalDrink
import androidx.compose.material.icons.rounded.RiceBowl
import androidx.compose.material.icons.rounded.ShoppingBasket
import androidx.compose.material.icons.rounded.CalendarMonth
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Eco
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.MilitaryTech
import androidx.compose.material.icons.rounded.NotificationsActive
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.WorkspacePremium
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.noop.R
import com.noop.core.CoreFoodNotes
import com.noop.core.CoreRead
import com.noop.ui.AppLanguagePrefs
import com.noop.ui.appLaunchIntent
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * Fork (DX23876), owner 2026-11-21: the day's food note, badges and the food reminders on Android, as iOS
 * `FoodNoteCard`, `FoodBadgesViews`, `FoodReminderInvite` and `FoodReminders`. Every figure comes from the core
 * (`CoreFoodNotes`); this file lays it out and delivers the reminders.
 */

/**
 * The day's nutrition quality, said before the number: a title, one sentence and the still life the detail page opens
 * on, then the note as a ring that fills to 10 in a colour that says how good it is, the word, and the week and month.
 */
@Composable
internal fun FoodNoteCard(quality: CoreFoodNotes.Quality, isToday: Boolean, onOpen: () -> Unit) {
    val colors = Forge.colors
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Rounded.Eco, null, tint = qualityLeaf(), modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(ForgeMetrics.space2))
                    Text(stringResource(R.string.food_quality_title), style = Forge.type.headline, color = colors.text)
                }
                Text(stringResource(R.string.food_quality_about), style = Forge.type.footnote, color = colors.textSecondary)
            }
            androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(R.drawable.food_score_hero), contentDescription = null,
                contentScale = androidx.compose.ui.layout.ContentScale.Crop, alignment = Alignment.CenterEnd,
                modifier = Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)))
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
            QualityRing(quality.day?.score, 88)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                Column {
                    Text(stringResource(if (quality.day?.provisional == true) R.string.food_note_today_so_far else R.string.food_span_day),
                         style = Forge.type.footnote, color = colors.textSecondary)
                    Text(quality.day?.let { qualityWord(it.score) } ?: "–", style = Forge.type.headline, color = qualityTint(quality.day?.score))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space4)) {
                    SmallNote(stringResource(R.string.food_span_week), quality.week)
                    SmallNote(stringResource(R.string.food_span_month), quality.month)
                }
            }
            Icon(Icons.Rounded.ChevronRight, null, tint = colors.textSecondary)
        }
        val goal = quality.goal
        val showsGoal = goal != null && (!isToday || goal.energy == "over")
        if (showsGoal || quality.streak >= 2) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                if (goal != null && showsGoal) {
                    GoalChip(stringResource(when (goal.energy) {
                        "inRange" -> R.string.food_goal_on; "over" -> R.string.food_goal_over
                        "under" -> R.string.food_goal_under; else -> R.string.food_goal_too_little
                    }), goal.energy == "inRange")
                    if (!isToday) goal.proteinMet?.let { GoalChip(stringResource(R.string.food_protein), it) }
                    if (!isToday) goal.carbsWithinCap?.let { GoalChip(stringResource(R.string.food_carbs), it) }
                }
                Spacer(Modifier.weight(1f))
                if (quality.streak >= 2) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.LocalFireDepartment, null, tint = colors.effort, modifier = Modifier.size(16.dp))
                        Text(java.text.NumberFormat.getIntegerInstance().format(quality.streak), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = colors.effort)
                    }
                }
            }
        }
        val line = when {
            quality.nothing -> stringResource(R.string.food_note_appears)
            quality.missingNeeded != null ->
                stringResource(R.string.food_note_counts_from_half, kcalText(quality.missingLogged), kcalText(quality.missingNeeded))
            quality.day?.uncertain == true -> stringResource(R.string.food_note_uncertain, percentText(1 - quality.day.placedShare))
            quality.day != null && quality.day.placedShare < 0.995 -> stringResource(R.string.food_note_unplaced, percentText(1 - quality.day.placedShare))
            else -> null
        }
        line?.let { Text(it, style = Forge.type.footnote, color = colors.textSecondary) }
    }
}

private fun percentText(share: Double): String = java.text.NumberFormat.getPercentInstance().format(share)

@Composable
private fun SmallNote(title: String, note: CoreFoodNotes.Note?) {
    Column {
        Text(title, style = Forge.type.footnote, color = Forge.colors.textSecondary)
        Text(note?.let { noteText(it.score) } ?: "–", style = Forge.type.title2, color = qualityTint(note?.score))
    }
}

@Composable
private fun qualityLeaf(): Color = nutrientTint("fiber_g", Forge.colors.dark)

/** Green from 7.5, yellow from 5.5, orange below, as iOS `FoodQualityRing.tint`. */
@Composable
internal fun qualityTint(score: Double?): Color = when {
    score == null -> Forge.colors.textSecondary
    score >= 7.5 -> qualityLeaf()
    score >= 5.5 -> Forge.colors.fat
    else -> Forge.colors.effort
}

@Composable
private fun qualityWord(score: Double): String = stringResource(when {
    score < 4 -> R.string.food_score_word_grow
    score < 6 -> R.string.food_score_word_fair
    score < 7.5 -> R.string.food_score_word_good
    else -> R.string.food_score_word_very_good
})

/** The note as a ring that fills to 10 in its quality colour, the note inside. */
@Composable
internal fun QualityRing(score: Double?, size: Int) {
    val track = Forge.colors.inset
    val tint = qualityTint(score)
    Box(Modifier.size(size.dp), contentAlignment = Alignment.Center) {
        androidx.compose.foundation.Canvas(Modifier.size(size.dp)) {
            val stroke = this.size.minDimension * 0.1f
            val inset = stroke / 2
            val arc = androidx.compose.ui.geometry.Size(this.size.width - stroke, this.size.height - stroke)
            val topLeft = androidx.compose.ui.geometry.Offset(inset, inset)
            drawArc(track, 0f, 360f, false, topLeft, arc, style = androidx.compose.ui.graphics.drawscope.Stroke(stroke))
            drawArc(tint, -90f, 360f * ((score ?: 0.0) / 10).toFloat().coerceIn(0f, 1f), false, topLeft, arc,
                    style = androidx.compose.ui.graphics.drawscope.Stroke(stroke, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(score?.let { noteText(it) } ?: "–", style = Forge.type.title1, color = Forge.colors.text)
            Text("/ 10", style = Forge.type.footnote, color = Forge.colors.textSecondary)
        }
    }
}

@Composable
private fun GoalChip(text: String, ok: Boolean) {
    Text(text, style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold),
         color = if (ok) Forge.colors.charge else Forge.colors.effort,
         modifier = Modifier.background(Forge.colors.inset, RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 5.dp))
}

// MARK: Badges

@Composable
internal fun badgeTitle(key: String): String = when (key) {
    "firstFullWeek" -> stringResource(R.string.food_badge_full_week)
    "days30" -> stringResource(R.string.food_badge_days30)
    "days100" -> stringResource(R.string.food_badge_days100)
    "goodWeek" -> stringResource(R.string.food_badge_good_week)
    "goodMonth" -> stringResource(R.string.food_badge_good_month)
    else -> stringResource(R.string.food_badge_habit, foodComponentName(key.removePrefix("habit.")))
}

@Composable
private fun badgeDetail(key: String): String = stringResource(when (key) {
    "firstFullWeek" -> R.string.food_badge_full_week_detail
    "days30", "days100" -> R.string.food_badge_days_detail
    "goodWeek" -> R.string.food_badge_good_week_detail
    "goodMonth" -> R.string.food_badge_good_month_detail
    else -> R.string.food_badge_habit_detail
})

private fun badgeIcon(key: String): ImageVector = when (key) {
    "firstFullWeek" -> Icons.Rounded.CalendarMonth
    "days30", "days100" -> Icons.Rounded.MilitaryTech
    "goodWeek", "goodMonth" -> Icons.Rounded.Star
    else -> habitIcon(key.removePrefix("habit."))
}

/** A habit badge's icon, one per part, so the medals can be told apart (iOS `FoodText.habitSymbol`). */
private fun habitIcon(component: String): ImageVector = when (component) {
    "vegetables" -> Icons.Rounded.Eco
    "fruit" -> Icons.Rounded.ShoppingBasket
    "wholeGrains" -> Icons.Rounded.RiceBowl
    "nutsLegumes" -> Icons.Rounded.Grass
    "redMeat" -> Icons.Rounded.OutdoorGrill
    "processedMeat" -> Icons.Rounded.LunchDining
    "fishOmega3" -> Icons.Rounded.SetMeal
    "freeSugar" -> Icons.Rounded.Cake
    "satFat" -> Icons.Rounded.Opacity
    "sodium" -> Icons.Rounded.Grain
    "alcohol" -> Icons.Rounded.WineBar
    else -> Icons.Rounded.Eco
}

@Composable
private fun badgeTint(key: String): Color = when {
    key.startsWith("habit.") -> Forge.colors.charge
    key == "goodWeek" || key == "goodMonth" -> Forge.colors.fat
    else -> Forge.colors.effort
}

@Composable
internal fun BadgeMedal(key: String, earned: Boolean, size: Int = 56) {
    Box(Modifier.size(size.dp).background(if (earned) badgeTint(key) else Forge.colors.inset, CircleShape),
        contentAlignment = Alignment.Center) {
        Icon(badgeIcon(key), null, tint = if (earned) Color.White else Forge.colors.textSecondary, modifier = Modifier.size((size * 0.45f).dp))
    }
}

/** The earned badges on the Food page and a way into the collection. */
@Composable
internal fun FoodBadgesStrip(quality: CoreFoodNotes.Quality, onOpen: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (quality.earned.isEmpty()) {
                Icon(Icons.Rounded.WorkspacePremium, null, tint = Forge.colors.textSecondary)
                Spacer(Modifier.width(ForgeMetrics.space2))
                Text(stringResource(R.string.food_badges_come_from), style = Forge.type.footnote, color = Forge.colors.textSecondary,
                     modifier = Modifier.weight(1f))
            } else {
                Box(Modifier.width((40 + 32 * (minOf(quality.earned.size, 4) - 1)).dp).heightIn(min = 40.dp)) {
                    quality.earned.takeLast(4).reversed().forEachIndexed { i, e ->
                        Box(Modifier.offset(x = (32 * i).dp)) { BadgeMedal(e.key, true, 40) }
                    }
                }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Text(stringResource(R.string.food_badges_count, quality.earned.size, CoreFoodNotes.allBadges.size),
                     style = Forge.type.headline, color = Forge.colors.text, modifier = Modifier.weight(1f))
            }
            Icon(Icons.Rounded.ChevronRight, null, tint = Forge.colors.textSecondary)
        }
    }
}

/** Every badge: what earns it, and when it was earned. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ForgeFoodBadgesPage(quality: CoreFoodNotes.Quality, onBack: () -> Unit) {
    SettingsColumn {
        PageTitle(stringResource(R.string.food_badges_title), onBack)
        if (quality.streak >= 1) {
            Text(androidx.compose.ui.res.pluralStringResource(R.plurals.food_streak_days, quality.streak, quality.streak),
                 style = Forge.type.headline, color = Forge.colors.effort)
        }
        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space3),
                verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space4), maxItemsInEachRow = 3) {
            CoreFoodNotes.allBadges.forEach { key ->
                val earned = quality.earned.firstOrNull { it.key == key }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally,
                       verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space1)) {
                    BadgeMedal(key, earned != null)
                    Text(badgeTitle(key), style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), textAlign = TextAlign.Center,
                         color = if (earned != null) Forge.colors.text else Forge.colors.textSecondary)
                    Text(earned?.let { LocalDate.parse(it.day).format(java.time.format.DateTimeFormatter.ofLocalizedDate(java.time.format.FormatStyle.MEDIUM)) }
                         ?: badgeDetail(key), style = Forge.type.footnote, color = Forge.colors.textSecondary, textAlign = TextAlign.Center)
                }
            }
        }
        Text(stringResource(R.string.food_badges_note), style = Forge.type.footnote, color = Forge.colors.textSecondary)
    }
}

/** The short celebration of a newly earned badge. */
@Composable
internal fun FoodBadgeCelebration(key: String, onDone: () -> Unit) {
    AlertDialog(onDismissRequest = onDone, icon = { BadgeMedal(key, true, 72) },
        title = { Text(badgeTitle(key), textAlign = TextAlign.Center) },
        text = { Text(badgeDetail(key), textAlign = TextAlign.Center) },
        confirmButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.food_badge_nice)) } })
}

/** Asks once whether the food reminders may start; they stay off until the wearer says yes. */
@Composable
internal fun FoodReminderInvite(onAccept: () -> Unit, onDecline: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.NotificationsActive, null, tint = Forge.colors.text)
            Spacer(Modifier.width(ForgeMetrics.space2))
            Text(stringResource(R.string.food_reminder_invite_title), style = Forge.type.headline, color = Forge.colors.text)
        }
        Text(stringResource(R.string.food_reminder_invite_body), style = Forge.type.body, color = Forge.colors.textSecondary)
        Row(horizontalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
            TextButton(onClick = onAccept, modifier = Modifier.background(Forge.colors.accent, RoundedCornerShape(50))) {
                Text(stringResource(R.string.food_reminder_turn_on), color = Forge.colors.onAccent)
            }
            TextButton(onClick = onDecline) { Text(stringResource(R.string.food_not_now), color = Forge.colors.textSecondary) }
        }
    }
}

// MARK: Reminders

/**
 * The food reminders, the same keys as iOS `FoodReminders`. The morning look back and the evening reminder are each one
 * WorkManager job that works out its words from the core when it fires, so they always read the log as it stands, and
 * plans the next one. Default off; turned on in Food data or from the page's one-time invitation.
 */
object FoodReminders {
    const val MORNING = "food.remind.morning"
    const val EVENING = "food.remind.evening"
    const val INVITED = "food.remind.invited"
    private const val SEEN = "food.badges.seen"

    private fun prefs(c: Context) = com.noop.ui.NoopPrefs.of(c)
    fun on(c: Context, key: String) = prefs(c).getBoolean(key, false)
    /** Turns a reminder on or off. The planning reads the core (blocking), so it runs off the main thread. */
    fun set(c: Context, key: String, value: Boolean) {
        prefs(c).edit().putBoolean(key, value).apply()
        val app = c.applicationContext
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch { schedule(app) }
    }
    fun invited(c: Context) = prefs(c).getBoolean(INVITED, false)
    fun markInvited(c: Context) = prefs(c).edit().putBoolean(INVITED, true).apply()

    /** Badges already celebrated, the same key as iOS. */
    fun seenBadges(c: Context): Set<String>? = prefs(c).getStringSet(SEEN, null)
    fun markSeen(c: Context, keys: Collection<String>) = prefs(c).edit().putStringSet(SEEN, keys.toSet()).apply()

    /** Plans the next morning and evening job from the wake time the coach learned and the sleep need. */
    fun schedule(c: Context, nowMs: Long = System.currentTimeMillis()) {
        val manager = runCatching { WorkManager.getInstance(c.applicationContext) }.getOrNull() ?: return
        val wake = runCatching { com.noop.core.CoreCoach.checkIn(7 * 60)?.wakeMinutes }.getOrNull() ?: (7 * 60)
        val need = com.noop.alarm.WindDownStore.from(c).sleepNeedMinutes
        val (morning, evening) = CoreFoodNotes.reminderTimes(wake, need)
        val zone = ZoneId.systemDefault()
        fun next(minutes: Int): Long {
            val today = LocalDate.now(zone).atStartOfDay(zone).plusMinutes(minutes.toLong()).toInstant().toEpochMilli()
            return if (today > nowMs) today else today + TimeUnit.DAYS.toMillis(1)
        }
        listOf(Triple(MORNING, morning, true), Triple(EVENING, evening, false)).forEach { (key, minutes, isMorning) ->
            if (!on(c, key)) { manager.cancelUniqueWork(key); return@forEach }
            val request = OneTimeWorkRequestBuilder<FoodReminderWorker>().setInputData(workDataOf("morning" to isMorning))
                .setInitialDelay(next(minutes) - nowMs, TimeUnit.MILLISECONDS).build()
            manager.enqueueUniqueWork(key, ExistingWorkPolicy.REPLACE, request)
        }
    }
}

class FoodReminderWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val c = applicationContext
        val morning = inputData.getBoolean("morning", true)
        runCatching { post(c, morning) }
        FoodReminders.schedule(c)
        return Result.success()
    }

    @SuppressLint("MissingPermission") // a disabled channel or revoked permission is checked at delivery
    private fun post(context: Context, morning: Boolean) {
        if (!FoodReminders.on(context, if (morning) FoodReminders.MORNING else FoodReminders.EVENING)) return
        val notifications = NotificationManagerCompat.from(context)
        if (!notifications.areNotificationsEnabled()) return
        CoreRead.open(context)
        val profile = com.noop.ui.ProfileStore.from(context)
        val plan = com.noop.core.CoreDietPlan.load(context)
        val l = AppLanguagePrefs.wrap(context)
        val today = LocalDate.now()
        // The goal of the day being looked back on, as the Food page resolves it.
        val goals = runCatching {
            com.noop.core.CoreDietPlan.dayGoal(context, plan, dietPerson(context), null, null, emptyMap(),
                                              (if (morning) today.minusDays(1) else today).toString(), emptyList(), null)
        }.getOrNull()
        val title: String
        val body: String
        if (morning) {
            // The look back runs on the day after, so it reads "yesterday" as the core's today.
            val yesterday = today.minusDays(1).toString()
            val recap = CoreFoodNotes.recap(yesterday, profile.sex, profile.age, profile.weightKg, profile.heightCm, plan?.form,
                                            goals?.kcal, goals?.proteinG, com.noop.core.CoreEnergyPlan.formulaLog(context),
                                            com.noop.core.CoreEnergyPlan.measuredBasal(context)) ?: return
            val score = recap.score ?: return
            title = when (recap.kind) {
                "week" -> l.getString(R.string.food_recap_week_title, noteText(score))
                "month" -> l.getString(R.string.food_recap_month_title, noteText(score))
                else -> l.getString(R.string.food_recap_day_title, noteText(score))
            }
            val lines = mutableListOf<String>()
            recap.previous?.let { prev ->
                val change = score - prev
                if (abs(change) >= 0.1) lines.add(l.getString(if (change > 0) R.string.food_recap_up else R.string.food_recap_down, noteText(abs(change))))
            }
            recap.strongest?.let { lines.add(l.getString(R.string.food_recap_strong, componentNameText(l, it))) }
            recap.weakest?.let { lines.add(l.getString(R.string.food_recap_room, componentNameText(l, it))) }
            when (recap.goal) {
                "over" -> lines.add(l.getString(R.string.food_recap_over))
                "belowFloor" -> lines.add(l.getString(R.string.food_recap_too_little))
                "inRange" -> lines.add(l.getString(R.string.food_recap_on_goal))
            }
            body = lines.joinToString(" ")
        } else {
            val gap = CoreFoodNotes.evening(today.toString(), goals?.proteinG) ?: return
            title = l.getString(R.string.food_evening_title)
            body = listOfNotNull(
                gap.proteinG?.let { l.getString(R.string.food_evening_protein, gramsText(it)) },
                gap.vegetablePortions?.let { l.getString(R.string.food_evening_vegetables, gramsText(it)) },
            ).joinToString(" ")
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, l.getString(R.string.food_reminder_channel), NotificationManager.IMPORTANCE_DEFAULT))
        val pending = PendingIntent.getActivity(context, 0, appLaunchIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        notifications.notify(if (morning) 4201 else 4202, NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_heart).setContentTitle(title).setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body)).setContentIntent(pending).setAutoCancel(true).build())
    }

    private companion object { const val CHANNEL = "noop_food" }
}

/** A part's name outside composition, for a notification. */
internal fun componentNameText(context: Context, c: String): String = context.getString(when (c) {
    "vegetables" -> R.string.food_part_vegetables
    "fruit" -> R.string.food_part_fruit
    "wholeGrains" -> R.string.food_part_whole_grains
    "nutsLegumes" -> R.string.food_part_nuts
    "redMeat" -> R.string.food_part_red_meat
    "processedMeat" -> R.string.food_part_processed_meat
    "fishOmega3" -> R.string.food_part_fish
    "freeSugar" -> R.string.food_part_free_sugar
    "satFat" -> R.string.food_part_sat_fat
    "sodium" -> R.string.food_part_salt
    "fiber" -> R.string.food_part_fibre
    else -> R.string.food_part_alcohol
})
