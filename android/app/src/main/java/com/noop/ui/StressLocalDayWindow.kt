package com.noop.ui

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/** Inclusive epoch-second bounds for one calendar day in a specific device time zone. */
internal data class StressLocalDayWindow(
    val day: LocalDate,
    val fromEpochSecond: Long,
    val toEpochSecondInclusive: Long,
    val offsetSeconds: Int,
) {
    val durationSeconds: Long get() = toEpochSecondInclusive - fromEpochSecond + 1L
}

/**
 * Resolve a local calendar day through the zone's rules instead of assuming every day is 86,400 s.
 * This mirrors Calendar.startOfDay/date(byAdding: .day) used by the Swift stress screen.
 */
internal fun stressLocalDayWindow(day: LocalDate, zone: ZoneId): StressLocalDayWindow {
    val start = day.atStartOfDay(zone)
    val nextStart = day.plusDays(1).atStartOfDay(zone)
    return StressLocalDayWindow(
        day = day,
        fromEpochSecond = start.toEpochSecond(),
        toEpochSecondInclusive = nextStart.toEpochSecond() - 1L,
        offsetSeconds = start.offset.totalSeconds,
    )
}

internal fun stressLocalDayWindowContaining(epochSecond: Long, zone: ZoneId): StressLocalDayWindow {
    val day = Instant.ofEpochSecond(epochSecond).atZone(zone).toLocalDate()
    return stressLocalDayWindow(day, zone)
}
