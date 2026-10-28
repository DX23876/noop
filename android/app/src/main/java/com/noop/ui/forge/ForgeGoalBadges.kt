package com.noop.ui.forge

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.DirectionsRun
import androidx.compose.material.icons.rounded.DirectionsWalk
import androidx.compose.material.icons.rounded.EmojiEvents
import androidx.compose.material.icons.rounded.EventAvailable
import androidx.compose.material.icons.rounded.LocalFireDepartment
import androidx.compose.material.icons.rounded.Map
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.noop.R
import com.noop.core.CoreGoals
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/**
 * Fork (DX23876), Android parity plan 2.3: badges, streaks and records as the iOS goals page shows them
 * (`NewBadgeBanner`, `AchievementsCard`, `GoalBadgesView`, `RecordsCard`, `BadgeMedal`). The core works them out
 * from the wearer's own data and words them (`CoreGoals.Motivation`); these only draw.
 */

/** The SF Symbol of a badge family, as its Material counterpart. */
private fun familyIcon(family: String): ImageVector = when (family) {
    "dailySteps" -> Icons.Rounded.DirectionsWalk
    "lifetimeSteps" -> Icons.Rounded.Map
    "stepStreak" -> Icons.Rounded.LocalFireDepartment
    "weeksReached" -> Icons.Rounded.EventAvailable
    else -> Icons.Rounded.DirectionsRun
}

/** A badge as a medal: filled once earned, an outline with the figure while ahead. */
@Composable
internal fun BadgeMedal(badge: CoreGoals.Badge, diameter: Dp = 58.dp, showsCaption: Boolean = true) {
    val colors = Forge.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(diameter).clip(CircleShape)
                .then(if (badge.earned) Modifier.background(colors.accent)
                      else Modifier.border(BorderStroke(2.dp, colors.textTertiary.copy(alpha = 0.5f)), CircleShape)),
            contentAlignment = Alignment.Center) {
            val tint = if (badge.earned) Color.White else colors.textTertiary
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(familyIcon(badge.family), contentDescription = null, tint = tint,
                     modifier = Modifier.size(diameter * 0.32f))
                Text(badge.shortValue, color = tint, maxLines = 1, fontWeight = FontWeight.Bold,
                     fontSize = (diameter.value * 0.17f).sp)
            }
        }
        if (showsCaption) {
            Text(badge.title, style = Forge.type.caption, textAlign = TextAlign.Center, maxLines = 2,
                 color = if (badge.earned) colors.text else colors.textTertiary)
            badge.earnedOn?.let { Text(badgeDate(it), style = Forge.type.caption, color = colors.textTertiary) }
        }
    }
}

private fun badgeDate(day: String): String = runCatching {
    LocalDate.parse(day).format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(Locale.getDefault()))
}.getOrDefault(day)

/** "New badge" at the top of the goals page: the row opens the badges, the cross only hides it. */
@Composable
internal fun NewBadgeBanner(badges: List<CoreGoals.Badge>, onOpen: () -> Unit, onSeen: () -> Unit) {
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).clickable(role = Role.Button) { onSeen(); onOpen() },
                verticalAlignment = Alignment.CenterVertically) {
                badges.firstOrNull()?.let { BadgeMedal(it, 40.dp, showsCaption = false) }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f)) {
                    Text(if (badges.size == 1) stringResource(R.string.forge_gm_new_badge)
                         else stringResource(R.string.forge_gm_new_badges, badges.size),
                         style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                    Text(badges.take(3).joinToString(" · ") { it.title }, style = Forge.type.caption,
                         color = Forge.colors.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Forge.colors.textTertiary)
            }
            IconButton(onClick = onSeen) {
                Icon(Icons.Rounded.Close, stringResource(R.string.forge_gm_hide), tint = Forge.colors.textTertiary)
            }
        }
    }
}

/**
 * The achievements row on the goals page (three medals, how many of all, the best day and the longest streak),
 * with the switch for badges, streaks and records iOS keeps in its goal settings.
 */
@Composable
internal fun AchievementsCard(motivation: CoreGoals.Motivation?, enabled: Boolean, onOpen: () -> Unit,
                              onSwitch: (Boolean) -> Unit) {
    GoalSectionHeader(stringResource(R.string.forge_gm_achievements))
    ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
        if (motivation != null) {
            Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClick = onOpen).padding(vertical = ForgeMetrics.space2),
                verticalAlignment = Alignment.CenterVertically) {
                Row {
                    motivation.earned.take(3).forEachIndexed { i, badge ->
                        Box(Modifier.offset(x = (-10 * i).dp)) { BadgeMedal(badge, 38.dp, showsCaption = false) }
                    }
                }
                Spacer(Modifier.width(ForgeMetrics.space3))
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.forge_gm_achievements),
                         style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                    val parts = buildList {
                        add(stringResource(R.string.forge_gm_of_badges, motivation.earned.size, motivation.badges.size))
                        motivation.bestStepDay?.let { add(stringResource(R.string.forge_gm_best_day_steps, steps(it))) }
                        if (motivation.longestStepStreak > 1) {
                            add(stringResource(R.string.forge_gm_longest_streak, motivation.longestStepStreak))
                        }
                    }
                    Text(parts.joinToString(" · "), style = Forge.type.caption, color = Forge.colors.textSecondary,
                         maxLines = 3)
                }
                Icon(Icons.Rounded.ChevronRight, contentDescription = null, tint = Forge.colors.textTertiary)
            }
            RowDivider()
        }
        ToggleRow(stringResource(R.string.forge_gm_toggle), detail = stringResource(R.string.forge_gm_toggle_detail),
                  checked = enabled, onChange = onSwitch)
    }
}

private fun steps(value: Int): String = java.text.NumberFormat.getIntegerInstance(Locale.getDefault()).format(value)

/** Every badge, by family: earned ones filled with their date, the rest as outlines; records first. */
@Composable
internal fun GoalBadgesPage(motivation: CoreGoals.Motivation?, onBack: () -> Unit) {
    // Opening the page counts as seeing every earned badge, as on iOS.
    LaunchedEffect(motivation?.earnedIds) {
        val ids = motivation?.earnedIds.orEmpty()
        if (ids.isNotEmpty()) withContext(Dispatchers.IO) { CoreGoals.changeMotivation(seen = ids) }
    }
    SettingsColumn {
        PageTitle(stringResource(R.string.forge_gm_achievements), onBack)
        Text(stringResource(R.string.forge_gm_page_subtitle), style = Forge.type.subhead, color = Forge.sceneInk.secondary)
        val m = motivation ?: return@SettingsColumn
        GoalSectionHeader(stringResource(R.string.forge_gm_records))
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            m.bestStepDay?.let { RecordLine(stringResource(R.string.forge_gm_best_day),
                                            stringResource(R.string.forge_gm_steps, steps(it)), m.bestStepDayOn) }
            m.bestStepWeek?.let { RecordLine(stringResource(R.string.forge_gm_best_week),
                                             stringResource(R.string.forge_gm_steps, steps(it)), m.bestStepWeekStart) }
            m.mostWorkoutsWeek?.let { RecordLine(stringResource(R.string.forge_gm_most_workouts), "$it", m.mostWorkoutsWeekStart) }
            if (m.longestStepStreak > 0) {
                RecordLine(stringResource(R.string.forge_gm_longest), stringResource(R.string.forge_gm_days, m.longestStepStreak), null)
            }
            if (m.bestStepDay == null && m.mostWorkoutsWeek == null) {
                Text(stringResource(R.string.forge_gm_records_empty), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            }
        }
        GoalSectionHeader(stringResource(R.string.forge_gm_badges) + " · ${m.earned.size}/${m.badges.size}")
        ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
            if (m.earned.isEmpty()) {
                Text(stringResource(R.string.forge_gm_first_badge), style = Forge.type.footnote, color = Forge.colors.textSecondary)
            } else {
                Row(Modifier.fillMaxWidth()) {
                    m.earned.take(3).forEach { badge ->
                        Box(Modifier.weight(1f), contentAlignment = Alignment.TopCenter) { BadgeMedal(badge, 56.dp) }
                    }
                }
            }
            val next = m.nextId?.let { id -> m.badges.firstOrNull { it.id == id } }
            if (next != null) {
                RowDivider()
                Row(verticalAlignment = Alignment.CenterVertically) {
                    BadgeMedal(next, 40.dp, showsCaption = false)
                    Spacer(Modifier.width(ForgeMetrics.space3))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(stringResource(R.string.forge_gm_next, next.title),
                             style = Forge.type.footnote.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
                        Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Forge.colors.inset)) {
                            Box(Modifier.fillMaxWidth((m.nextFraction ?: 0.0).coerceIn(0.0, 1.0).toFloat()).height(6.dp)
                                .clip(RoundedCornerShape(3.dp)).background(Forge.colors.accent))
                        }
                    }
                }
            }
        }
        m.badges.groupBy { it.family }.forEach { (_, items) ->
            GoalSectionHeader(items.first().familyTitle + " · ${items.count { it.earned }}/${items.size}")
            ForgeCard(Modifier.fillMaxWidth(), radius = ForgeMetrics.groupedRadius) {
                items.chunked(3).forEach { row ->
                    Row(Modifier.fillMaxWidth().padding(vertical = ForgeMetrics.space2)) {
                        row.forEach { badge ->
                            Box(Modifier.weight(1f), contentAlignment = Alignment.TopCenter) { BadgeMedal(badge, 60.dp) }
                        }
                        repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun RecordLine(label: String, value: String, day: String?) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Rounded.EmojiEvents, contentDescription = null, tint = ForgeTokens.StrandPalette.statusWarning.resolve(),
             modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(ForgeMetrics.space3))
        Column(Modifier.weight(1f)) {
            Text(label, style = Forge.type.footnote, color = Forge.colors.text)
            day?.let { Text(badgeDate(it), style = Forge.type.caption, color = Forge.colors.textTertiary) }
        }
        Text(value, style = Forge.type.subhead.copy(fontWeight = FontWeight.SemiBold), color = Forge.colors.text)
    }
}
