package com.noop.analytics

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

/** One imported body-weight reading: the ISO `yyyy-MM-dd` day it belongs to, in kilograms. */
data class WeightReading(val day: String, val kg: Double)

/**
 * The single resolver behind "Use weight from Health Connect".
 *
 * Two readers need the same fact: the sync that copies the newest Health Connect weight into the
 * profile (which every analytics pass reads), and the Today Weight tile. Both pick it through [newest],
 * so with the sync ON the tile and the profile cannot name different weights. No Android imports, so it
 * runs as a plain JVM test.
 */
object ProfileWeightSync {

    /**
     * The newest reading, or null when there is none. Days are ISO `yyyy-MM-dd`, which sorts
     * chronologically, so the lexically greatest day is the most recent and no date parsing is needed.
     *
     * Resolution is day-granular, and on a tie `maxByOrNull` keeps the FIRST maximal element, so input
     * order decides. That ordering is load-bearing, not incidental: the Weight tile's default path
     * passes `apple + healthConnect`, two different `deviceId`s that each hold at most one `appleDaily`
     * row per day (natural key `(deviceId, day)`), so both sources CAN carry the same day. Prepending
     * Apple Health makes it win that day, which is the behaviour the tile had before this resolver
     * existed. Reversing the concatenation would silently change which source the tile names.
     *
     * Two weigh-ins on ONE day from one source never reach here: `HealthConnectImporter` already keeps
     * the day's latest by timestamp (`r.time.epochSecond >= b.weightTs`) before the row is stored, so
     * each `deviceId` contributes one already-latest reading per day. The profile sync is narrower
     * still, reading only the `health-connect` bucket, so it sees no same-day tie at all.
     */
    fun newest(readings: List<WeightReading>): WeightReading? = readings.maxByOrNull { it.day }

    /**
     * "25 Sep" in the app language for the Settings caption, verbatim on an unparseable day.
     * [locale] defaults to [Locale.getDefault], which `AppLanguagePrefs` keeps on the selected app
     * language, so an Italian UI reads "25 set" rather than an English month.
     */
    fun captionDate(day: String, locale: Locale = Locale.getDefault()): String =
        runCatching { LocalDate.parse(day).format(DateTimeFormatter.ofPattern("d MMM", locale)) }
            .getOrDefault(day)
}
