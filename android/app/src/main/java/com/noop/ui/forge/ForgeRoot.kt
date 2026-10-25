package com.noop.ui.forge

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource

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
}

@Composable
fun ForgeRoot() {
    ForgeShell { tab, padding, width ->
        when (tab) {
            ForgeTab.Today -> ForgeTodayScreen(padding, width)
            ForgeTab.Trends -> ForgeTrendsScreen(padding, width)
            ForgeTab.Sleep -> ForgeSleepScreen(padding, width)
            else -> Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.Center) {
                Text(stringResource(tab.labelRes), style = Forge.type.title2, color = Forge.colors.text)
            }
        }
    }
}
