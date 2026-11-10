package com.noop.ui.forge

import androidx.compose.foundation.layout.padding
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.noop.ui.AppViewModel

/**
 * Fork (DX23876), Android plan E-3: the Forge app, shown by `NoopRoot` after the terms and onboarding gates with
 * the app's view model. They are the default; More switches to the classic screens for what they do not cover
 * yet, and the classic Settings switch back. `--ez forge_ui true|false` on the launch intent sets the choice too.
 */
object ForgeUi {
    private const val PREFS = "forge"
    private const val KEY = "ui"
    const val EXTRA = "forge_ui"
    /** The Forge screens are the app (E-3f); More switches to the classic screens and their Settings back. */
    const val DEFAULT = true

    fun enabled(context: Context, intent: Intent?): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (intent?.hasExtra(EXTRA) == true) prefs.edit().putBoolean(KEY, intent.getBooleanExtra(EXTRA, false)).apply()
        return prefs.getBoolean(KEY, DEFAULT)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, enabled).commit()
    }

    /** Starts the app afresh, so a restored store or the other screen set is what it opens with. */
    fun restart(context: Context) {
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        context.startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        Runtime.getRuntime().exit(0)
    }
}

@Composable
fun ForgeRoot(viewModel: AppViewModel) {
    val context = LocalContext.current
    remember { ForgeBackground.load(context) }
    remember { ForgeDesign.load(context, (context as? android.app.Activity)?.intent) }
    // Settings and pairing open over the tabs in the same window (`ForgeOverlayHost`).
    var moreOpen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    ForgeOverlayHost {
        androidx.compose.runtime.CompositionLocalProvider(
            LocalForgeOpenMore provides (if (ForgeDesign.preview) ({ moreOpen = true }) else null)) {
        ForgeShell { tab, padding, width ->
            when (tab) {
                ForgeTab.Today ->
                    if (DashboardStylePrefs.style(context) == "classic") ForgeClassicToday(padding, viewModel)
                    else ForgeTodayScreen(padding, width, viewModel)
                ForgeTab.Trends -> ForgeTrendsScreen(padding, width, viewModel)
                ForgeTab.Health -> ForgeHealthTab(padding, width, viewModel)
                ForgeTab.Training -> ForgeTrainingScreen(padding, viewModel)
                ForgeTab.Sleep -> ForgeSleepScreen(padding, width, viewModel)
                ForgeTab.More -> ForgeMoreScreen(padding, viewModel)
                // The chat in its tab, as iOS (2026-11); leaving it returns to Today.
                ForgeTab.Coach -> {
                    val select = LocalForgeTabSelect.current
                    androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.padding(padding)) {
                        ForgeCoachChatPages(viewModel, androidx.compose.ui.res.stringResource(com.noop.R.string.nav_coach),
                                            onBack = { select(ForgeTab.Today) })
                    }
                }
            }
        }
        }
        if (moreOpen && ForgeDesign.preview) ForgeMoreOverlay(viewModel, onDismiss = { moreOpen = false })
        // In the new design the coach has its own place while it is on (`ForgeTab.Coach`: a button beside the bar, a
        // rail entry on wide windows), as on iOS; the floating button is for the shipped tabs and a coach that is off.
        if (!(ForgeDesign.preview && com.noop.ui.BottomBarStyleStore.coachEnabled)) ForgeCoachButton(viewModel)
    }
}
