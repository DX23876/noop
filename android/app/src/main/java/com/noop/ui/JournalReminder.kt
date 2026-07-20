package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.data.DailyMetric

/** How many days the completion strip shows (a week, ending today). */
private const val JOURNAL_STRIP_DAYS = 7

/**
 * JournalReminderCard — a persistent Today widget for the journal (#627).
 *
 * The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
 * inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
 * prompt today is the once-a-morning sleep sheet (PR #260) that a user skips whenever they don't open
 * Sleep. This surfaces, on Today where it can't be missed, a WHOOP-style strip of the last
 * [JOURNAL_STRIP_DAYS] days (filled = logged that day, today ringed) plus an always-present tap-through
 * to the journal — so it doubles as a reminder AND the "direct link to Insights" the report asked for.
 *
 * Opt-out via [NoopPrefs.journalReminderEnabled] (default ON — the same toggle also gates the morning
 * sleep sheet, so one switch silences both). Renders only for today (the call site gates
 * `selectedDayOffset == 0`) once the completion read returns. Read-only: it never writes a journal entry.
 * The whole card taps through to the journal; when today isn't logged yet the subtitle nudges in accent.
 *
 * iOS twin `JournalReminderCard.swift` is a fast-follow. Design-Reset compliant — a flat accent-tinted
 * [NoopCard], NoopType/Palette tokens, matching the other Today cards.
 */
@Composable
fun JournalReminderCard(
    viewModel: AppViewModel,
    days: List<DailyMetric>,
    onOpenJournal: () -> Unit,
) {
    val context = LocalContext.current
    // Read once — SharedPreferences isn't reactive; when off the whole card is invisible + inert.
    val enabled = remember { NoopPrefs.journalReminderEnabled(context) }
    if (!enabled) return

    // The N day keys the strip covers, oldest (left) → today (right). journalDayKey(n) = today − n days,
    // the same wake/cycle key the logging card writes under, so a filled cell == "logged that day".
    val dayKeys = remember { (JOURNAL_STRIP_DAYS - 1 downTo 0).map { journalDayKey(it.toLong()) } }
    val todayKey = dayKeys.last()

    // Which of those days have any journal entry. null = still loading / read error → render nothing.
    var loggedDays by remember { mutableStateOf<Set<String>?>(null) }
    // Re-query whenever Today's data refreshes (a resume/sync bumps `days`) so the strip and the "logged
    // today" state stay current after the user logs the journal and comes back. Mirrors AutoWorkoutNudge.
    LaunchedEffect(days) {
        loggedDays = runCatching {
            viewModel.repo.journal(JOURNAL_DEVICE_ID, dayKeys.first(), todayKey)
                .map { it.day }.toSet()
        }.getOrNull()
    }

    val logged = loggedDays ?: return
    val todayLogged = todayKey in logged
    val openLabel = uiString(R.string.l10n_journal_reminder_open_journal_bbd88cc1)

    NoopCard(
        tint = Palette.accent,
        // Tapping anywhere but a specific bar opens the journal at TODAY (#656). Deliberately does NOT
        // set a pending day: `pendingJournalDayOffset` is cleared on every Insights open, so "no pending"
        // already means today — and NOT touching it here means a bar's tap (which sets its own day) still
        // wins even in the edge case where a nested-click delivers both taps.
        modifier = Modifier.clickable(onClickLabel = openLabel) { onOpenJournal() },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Filled.MenuBook,
                    contentDescription = null,
                    tint = Palette.accent,
                    modifier = Modifier.size(18.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    uiString(R.string.l10n_journal_reminder_journal_57d7f743),
                    style = NoopType.headline,
                    color = Palette.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Filled.ChevronRight,
                    contentDescription = null,
                    tint = Palette.textTertiary,
                    modifier = Modifier.size(18.dp),
                )
            }
            // The last-N-days strip: one equal-width bar per day. Filled = logged; today is ringed so the
            // orientation is unambiguous even when nothing is logged yet. Each bar is its own tap target
            // (#656): tapping a day deep-links the journal to THAT day (requestJournalDay) instead of always
            // today. The bar sits in a taller invisible Box so the tap target isn't a 10dp sliver.
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                val shape = RoundedCornerShape(3.dp)
                dayKeys.forEachIndexed { i, key ->
                    val off = (JOURNAL_STRIP_DAYS - 1 - i).toLong()   // dayKeys[0] = 6 days ago … [last] = today
                    val isLogged = key in logged
                    val isToday = off == 0L
                    Box(
                        modifier = Modifier
                            .weight(1f)
                            .height(22.dp)
                            .clickable(onClickLabel = openLabel) {
                                viewModel.requestJournalDay(off)
                                onOpenJournal()
                            }
                            // Each bar is otherwise an identical sliver to a screen reader; name its day
                            // (from the shared label helper — not a literal, so no i18n regression) so the
                            // deep-link target is announced (#656). Logged state is conveyed visually.
                            .semantics { contentDescription = journalDayChipLabel(off) },
                        contentAlignment = Alignment.Center,
                    ) {
                        var bar = Modifier
                            .fillMaxWidth()
                            .height(10.dp)
                            .background(
                                if (isLogged) Palette.accent else Palette.textTertiary.copy(alpha = 0.22f),
                                shape,
                            )
                        if (isToday && !isLogged) bar = bar.border(1.dp, Palette.accent, shape)
                        Spacer(bar)
                    }
                }
            }
            // A recent PAST day with no entry — surfaces the (otherwise invisible) tap-a-bar-to-backfill
            // interaction once today is done. #656.
            val hasMissed = dayKeys.any { it != todayKey && it !in logged }
            Text(
                when {
                    !todayLogged -> uiString(R.string.l10n_journal_reminder_log_today_s_journal_cb33be3e)
                    hasMissed -> uiString(R.string.l10n_journal_reminder_tap_a_day_to_catch_up_10d16728)
                    else -> uiString(R.string.l10n_journal_reminder_logged_today_0071a46c)
                },
                style = NoopType.footnote,
                // Accent while there's something actionable (log today, or catch up a missed day);
                // calm secondary once fully caught up.
                color = if (!todayLogged || hasMissed) Palette.accent else Palette.textSecondary,
            )
        }
    }
}
