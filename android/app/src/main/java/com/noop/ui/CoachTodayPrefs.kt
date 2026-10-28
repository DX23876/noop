package com.noop.ui

import android.content.Context

/**
 * The coach's Today entry, as iOS keeps it (`CoachEntryPrefs`): whether the coach shows on Today at all
 * (`coach.uiEnabled`, default on) and whether its card carries the coach's picture or a plain icon
 * (`coach.todayAvatar`, default on). Both sit under the master switch: off there, nothing shows either way.
 */
object CoachTodayPrefs {
    private const val UI_KEY = "coach.uiEnabled"
    private const val AVATAR_KEY = "coach.todayAvatar"

    fun shown(context: Context): Boolean = NoopPrefs.of(context).getBoolean(UI_KEY, true)
    fun setShown(context: Context, on: Boolean) = NoopPrefs.of(context).edit().putBoolean(UI_KEY, on).apply()
    fun avatar(context: Context): Boolean = NoopPrefs.of(context).getBoolean(AVATAR_KEY, true)
    fun setAvatar(context: Context, on: Boolean) = NoopPrefs.of(context).edit().putBoolean(AVATAR_KEY, on).apply()
}
