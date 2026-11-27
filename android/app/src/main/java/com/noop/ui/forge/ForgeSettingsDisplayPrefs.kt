package com.noop.ui.forge

import android.content.Context
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import com.noop.ui.NoopPrefs

/**
 * The first day of the week, iOS's `TrainingPreferences.weekStartKey` (`training.weekStartsOn`, "monday" or "sunday").
 * Training, the weekly review and the week strips read it; the core takes it as an argument of the calls that need
 * it, so no core key is involved. [sundayFirst] reads a counter first, so a screen that is open redraws as soon as
 * Settings changes the day.
 */
object WeekStartPrefs {
    const val KEY = "training.weekStartsOn"
    private const val SUNDAY = "sunday"
    private const val MONDAY = "monday"
    private var version by mutableIntStateOf(0)

    fun sundayFirst(context: Context): Boolean {
        version
        return NoopPrefs.of(context).getString(KEY, null) == SUNDAY
    }

    fun set(context: Context, sunday: Boolean) {
        NoopPrefs.of(context).edit().putString(KEY, if (sunday) SUNDAY else MONDAY).apply()
        version++
    }
}

/**
 * How solid Today's tiles and notes are over the day's picture, in percent: iOS's `ForgeDesignPrefs.todaySurfaceKey`
 * (`forge.today.surfacePercent`, 75 by default). Today provides it as [LocalTodaySurface] and [ForgeCard] reads it
 * there, so only Today follows it; every other page keeps the Card transparency setting.
 */
object TodaySurfacePrefs {
    const val KEY = "forge.today.surfacePercent"
    const val DEFAULT = 75
    private var version by mutableIntStateOf(0)

    fun percent(context: Context): Int {
        version
        return NoopPrefs.of(context).getInt(KEY, DEFAULT).coerceIn(0, 100)
    }

    fun set(context: Context, percent: Int) {
        NoopPrefs.of(context).edit().putInt(KEY, percent.coerceIn(0, 100)).apply()
        version++
    }
}

/** The opacity Today gives its cards, or null where the Card transparency setting rules. */
val LocalTodaySurface = compositionLocalOf<Float?> { null }

/**
 * The coach button's slow pulse, iOS's `CoachTilePrefs.breathingKey` (`noop.coachTileBreathing`, on by default).
 * The system's and the app's own Reduce motion settings still hold it still whatever this says.
 */
object CoachBreathPrefs {
    const val KEY = "noop.coachTileBreathing"
    private var version by mutableIntStateOf(0)

    fun enabled(context: Context): Boolean {
        version
        return NoopPrefs.of(context).getBoolean(KEY, true)
    }

    fun set(context: Context, on: Boolean) {
        NoopPrefs.of(context).edit().putBoolean(KEY, on).apply()
        version++
    }
}
