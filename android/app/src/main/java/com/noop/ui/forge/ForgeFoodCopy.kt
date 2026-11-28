package com.noop.ui.forge

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.ChevronLeft
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.noop.R
import com.noop.core.CoreFood
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.time.format.TextStyle
import java.time.temporal.WeekFields
import java.util.Locale

/**
 * Copy a meal to days picked in a month calendar, iOS's `FoodCopySheet`. A repeat fills in chosen weekdays up to a
 * date, so one breakfast goes to every weekday for months at a time (tester request 2026-11-28); the days come from
 * the core (`food.repeatDays`). Single days are then ticked or unticked in the calendar.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FoodCopyDialog(day: LocalDate, onDismiss: () -> Unit, onCopy: (List<String>) -> Unit) {
    val colors = Forge.colors
    val locale = Locale.getDefault()
    val chosen = remember { mutableStateListOf<LocalDate>() }
    var month by remember { mutableStateOf(YearMonth.from(day)) }
    // Monday to Friday to start with.
    val weekdays = remember { mutableStateListOf(DayOfWeek.MONDAY, DayOfWeek.TUESDAY, DayOfWeek.WEDNESDAY, DayOfWeek.THURSDAY, DayOfWeek.FRIDAY) }
    var until by remember { mutableStateOf(day.plusDays(28)) }
    var pickingUntil by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val firstDay = WeekFields.of(locale).firstDayOfWeek
    val order = (0L until 7L).map { firstDay.plus(it) }
    // Month and year in the order and form the reader's locale writes them.
    val monthTitle = remember(locale) {
        DateTimeFormatter.ofPattern(android.text.format.DateFormat.getBestDateTimePattern(locale, "yMMMM"), locale)
    }

    fun selectRepeat() {
        // The core counts weekdays as Apple's calendar does, 1 = Sunday to 7 = Saturday.
        val numbers = weekdays.map { it.value % 7 + 1 }
        scope.launch {
            val days = withContext(Dispatchers.IO) { CoreFood.repeatDays(day.toString(), until.toString(), numbers) }
            days.map(LocalDate::parse).forEach { if (it !in chosen) chosen.add(it) }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.food_copy_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(ForgeMetrics.space2)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { month = month.minusMonths(1) }) {
                        Icon(Icons.Rounded.ChevronLeft, contentDescription = stringResource(R.string.food_copy_prev_month), tint = colors.text)
                    }
                    Text(month.format(monthTitle), style = Forge.type.headline,
                         color = colors.text, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                    IconButton(onClick = { month = month.plusMonths(1) }) {
                        Icon(Icons.Rounded.ChevronRight, contentDescription = stringResource(R.string.food_copy_next_month), tint = colors.text)
                    }
                }
                Row(Modifier.fillMaxWidth()) {
                    order.forEach { dow ->
                        Text(dow.getDisplayName(TextStyle.NARROW_STANDALONE, locale), style = Forge.type.caption,
                             color = colors.textSecondary, textAlign = TextAlign.Center, modifier = Modifier.weight(1f))
                    }
                }
                val lead = (month.atDay(1).dayOfWeek.value - firstDay.value + 7) % 7
                val cells: List<LocalDate?> = List(lead) { null } + (1..month.lengthOfMonth()).map { month.atDay(it) }
                cells.chunked(7).forEach { week ->
                    Row(Modifier.fillMaxWidth()) {
                        (0 until 7).forEach { i ->
                            val date = week.getOrNull(i)
                            Box(Modifier.weight(1f).aspectRatio(1f).padding(2.dp), contentAlignment = Alignment.Center) {
                                // The shown day is marked but cannot be chosen: copying a meal onto its own day only doubles it.
                                if (date != null) DayCell(date, on = date in chosen, shown = date == day) {
                                    if (date in chosen) chosen.remove(date) else if (date != day) chosen.add(date)
                                }
                            }
                        }
                    }
                }
                Text(stringResource(R.string.food_copy_chosen, chosen.size), style = Forge.type.footnote, color = colors.textSecondary)
                Text(stringResource(R.string.food_copy_repeat), style = Forge.type.headline, color = colors.text,
                     modifier = Modifier.padding(top = ForgeMetrics.space2))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    order.forEach { dow ->
                        val on = dow in weekdays
                        val name = dow.getDisplayName(TextStyle.FULL_STANDALONE, locale)
                        Box(Modifier.weight(1f).height(36.dp).clip(CircleShape).background(if (on) colors.accent else colors.inset)
                                .clickable(role = Role.Checkbox) { if (on) weekdays.remove(dow) else weekdays.add(dow) }
                                .semantics { contentDescription = name; selected = on },
                            contentAlignment = Alignment.Center) {
                            Text(dow.getDisplayName(TextStyle.NARROW_STANDALONE, locale), style = Forge.type.subhead,
                                 color = if (on) colors.onAccent else colors.text)
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(stringResource(R.string.food_copy_until), style = Forge.type.body, color = colors.text, modifier = Modifier.weight(1f))
                    TextButton(onClick = { pickingUntil = true }) {
                        Text(until.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale)))
                    }
                }
                TextButton(onClick = ::selectRepeat, enabled = weekdays.isNotEmpty()) { Text(stringResource(R.string.food_copy_select)) }
                Text(stringResource(R.string.food_copy_note), style = Forge.type.footnote, color = colors.textSecondary)
            }
        },
        confirmButton = {
            TextButton(onClick = { onCopy(chosen.filter { it != day }.distinct().sorted().map { it.toString() }) },
                       enabled = chosen.any { it != day }) {
                Text(stringResource(R.string.food_copy_go))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.food_cancel)) } },
    )

    if (pickingUntil) {
        val zone = ZoneOffset.UTC
        val state = rememberDatePickerState(
            initialSelectedDateMillis = until.atStartOfDay(zone).toInstant().toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean =
                    Instant.ofEpochMilli(utcTimeMillis).atZone(zone).toLocalDate().isAfter(day)
            })
        DatePickerDialog(onDismissRequest = { pickingUntil = false }, confirmButton = {
            TextButton(onClick = {
                state.selectedDateMillis?.let { until = Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
                pickingUntil = false
            }) { Text(stringResource(R.string.forge_g_done)) }
        }) { DatePicker(state) }
    }
}

/** One day of the copy calendar: filled when chosen, the shown day in the accent colour and not choosable. */
@Composable
private fun DayCell(date: LocalDate, on: Boolean, shown: Boolean, toggle: () -> Unit) {
    val colors = Forge.colors
    Box(Modifier.fillMaxSize().clip(CircleShape).background(if (on) colors.accent else Color.Transparent)
            .clickable(enabled = !shown, role = Role.Checkbox, onClick = toggle).semantics { selected = on },
        contentAlignment = Alignment.Center) {
        Text(date.dayOfMonth.toString(), style = Forge.type.body,
             color = when { on -> colors.onAccent; shown -> colors.accent; else -> colors.text })
    }
}
