package com.noop.ui

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue

/**
 * The coach's Today entries, as iOS keeps them (`CoachEntryPrefs`, `CoachButtonCorner`): whether the coach shows on
 * Today at all (`coach.uiEnabled`, default on), whether its card carries the coach's picture or a plain icon
 * (`coach.todayAvatar`), and the two entries it governs, the banner (`coach.entry.banner`) and the floating button
 * (`coach.entry.floatingButton`), each on by default. The button rests in one of four corners (`coach.fab.corner`)
 * or where the wearer dragged it (`custom`, at `coach.fab.fx`/`fy` as fractions of the window), and can be locked
 * (`coach.fab.locked`). All of it sits under the master switch: off there, nothing shows either way.
 */
object CoachTodayPrefs {
    private const val UI_KEY = "coach.uiEnabled"
    private const val AVATAR_KEY = "coach.todayAvatar"
    private const val BANNER_KEY = "coach.entry.banner"
    private const val FLOATING_KEY = "coach.entry.floatingButton"
    private const val CORNER_KEY = "coach.fab.corner"
    private const val LOCKED_KEY = "coach.fab.locked"
    private const val FX_KEY = "coach.fab.fx"
    private const val FY_KEY = "coach.fab.fy"

    /** The four corners the settings offer; `custom` is reached by dragging. */
    val corners = listOf("topLeading", "topTrailing", "bottomLeading", "bottomTrailing")

    /** Bumped on every change, so a screen reading these prefs draws again when Settings changes them. */
    var version by mutableIntStateOf(0)
        private set

    private fun edit(context: Context, block: android.content.SharedPreferences.Editor.() -> Unit) {
        NoopPrefs.of(context).edit().apply(block).apply()
        version++
    }

    fun shown(context: Context): Boolean = NoopPrefs.of(context).getBoolean(UI_KEY, true)
    fun setShown(context: Context, on: Boolean) = edit(context) { putBoolean(UI_KEY, on) }
    fun avatar(context: Context): Boolean = NoopPrefs.of(context).getBoolean(AVATAR_KEY, true)
    fun setAvatar(context: Context, on: Boolean) = edit(context) { putBoolean(AVATAR_KEY, on) }
    fun banner(context: Context): Boolean = NoopPrefs.of(context).getBoolean(BANNER_KEY, true)
    fun setBanner(context: Context, on: Boolean) = edit(context) { putBoolean(BANNER_KEY, on) }
    fun floating(context: Context): Boolean = NoopPrefs.of(context).getBoolean(FLOATING_KEY, true)
    fun setFloating(context: Context, on: Boolean) = edit(context) { putBoolean(FLOATING_KEY, on) }

    /** The pinned corner, or `custom`. A spot dragged before corners existed counts as `custom` (`migrateIfNeeded`). */
    fun corner(context: Context): String {
        val p = NoopPrefs.of(context)
        return p.getString(CORNER_KEY, null) ?: if (p.getFloat(FX_KEY, -1f) >= 0f) "custom" else "bottomTrailing"
    }
    fun setCorner(context: Context, corner: String) = edit(context) { putString(CORNER_KEY, corner) }
    fun locked(context: Context): Boolean = NoopPrefs.of(context).getBoolean(LOCKED_KEY, false)
    fun setLocked(context: Context, on: Boolean) = edit(context) { putBoolean(LOCKED_KEY, on) }

    /** The dragged spot as fractions of the window, or null before the first drag. */
    fun spot(context: Context): Pair<Float, Float>? {
        val p = NoopPrefs.of(context)
        val x = p.getFloat(FX_KEY, -1f); val y = p.getFloat(FY_KEY, -1f)
        return if (x < 0f || y < 0f) null else x to y
    }
    fun setSpot(context: Context, x: Float, y: Float) = edit(context) {
        putFloat(FX_KEY, x); putFloat(FY_KEY, y); putString(CORNER_KEY, "custom")
    }
}
