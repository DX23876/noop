package com.noop.ui.forge

import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable

/**
 * Fork (DX23876), Android plan E-3: the Forge app. Until the last E-3 step makes it the app, it opens only when
 * switched on: `adb shell am start -n <package>/com.noop.ui.MainActivity --ez forge_ui true` turns it on and
 * `--ez forge_ui false` off again; the choice is kept.
 */
object ForgeUi {
    private const val PREFS = "forge"
    private const val KEY = "ui"
    const val EXTRA = "forge_ui"

    fun enabled(context: Context, intent: Intent?): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (intent?.hasExtra(EXTRA) == true) prefs.edit().putBoolean(KEY, intent.getBooleanExtra(EXTRA, false)).apply()
        return prefs.getBoolean(KEY, false)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, enabled).commit()
    }
}

@Composable
fun ForgeRoot() {
    ForgeShell { tab, padding, width ->
        when (tab) {
            ForgeTab.Today -> ForgeTodayScreen(padding, width)
            ForgeTab.Trends -> ForgeTrendsScreen(padding, width)
            ForgeTab.Sleep -> ForgeSleepScreen(padding, width)
            ForgeTab.More -> ForgeMoreScreen(padding)
        }
    }
}
