package com.noop.ui.forge

import androidx.compose.foundation.layout.padding
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.noop.ui.AppViewModel
import kotlinx.coroutines.launch

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
    // A dashboard style this build dropped hands its arrangement to the style it resolves to, once.
    remember { DashboardStylePrefs.migrateRetiredStyle(context) }
    // The workout list Today's timeline, its latest-workout card, the dashboards and Training's count read: the view
    // model filled it only when the Workouts page, Insights or Data Sources opened, so those stayed empty until then.
    // Loaded at start and again after each analysis pass, when a synced workout can have arrived.
    val coreRevision by com.noop.core.CoreShadow.dataRevision.collectAsState()
    androidx.compose.runtime.LaunchedEffect(coreRevision) { viewModel.loadWorkouts() }
    // Settings and pairing open over the tabs in the same window (`ForgeOverlayHost`).
    var moreOpen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    var settingsOpen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    // The coach sheet (owner, 2026-11-21): the new design's coach lives in each page's header, not in a tab.
    var coachOpen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableStateOf(false) }
    val coachScope = androidx.compose.runtime.rememberCoroutineScope()
    val openCoach: ((CoachPage?) -> Unit)? =
        if (ForgeDesign.preview && com.noop.ui.BottomBarStyleStore.coachEnabled) { page ->
            if (page != null) {
                val suggestions = coachPageSuggestions(context, page.kind)
                coachScope.launch(kotlinx.coroutines.Dispatchers.IO) { com.noop.core.CoreCoach.page(page.kind, page.day, suggestions) }
            }
            coachOpen = true
        } else null
    ForgeOverlayHost {
        androidx.compose.runtime.CompositionLocalProvider(
            LocalForgeOpenMore provides (if (ForgeDesign.preview) ({ moreOpen = true }) else null),
            LocalForgeOpenSettings provides (if (ForgeDesign.preview) ({ settingsOpen = true }) else null),
            LocalForgeOpenCoach provides openCoach,
            // The tabs lie under the More page while it is open.
            LocalForgeCovered provides (LocalForgeCovered.current || (moreOpen && ForgeDesign.preview))) {
        ForgeShell { tab, padding, width ->
            when (tab) {
                // The new design has one Today whatever the dashboard style, as iOS; the classic page jumps to tabs
                // the new design does not have.
                ForgeTab.Today ->
                    if (!ForgeDesign.preview && DashboardStylePrefs.style(context) == "classic") ForgeClassicToday(padding, viewModel)
                    else ForgeTodayScreen(padding, width, viewModel)
                ForgeTab.Trends -> ForgeTrendsScreen(padding, width, viewModel)
                ForgeTab.Health -> ForgeHealthTab(padding, width, viewModel)
                ForgeTab.Training -> ForgeTrainingScreen(padding, viewModel)
                ForgeTab.Sleep -> ForgeSleepScreen(padding, width, viewModel)
                ForgeTab.More -> ForgeMoreScreen(padding, viewModel)
                // The food log in its own tab (owner, 2026-11-21); leaving it returns to Today, as the coach's tab.
                ForgeTab.Nutrition -> {
                    val select = LocalForgeTabSelect.current
                    androidx.activity.compose.BackHandler { select(ForgeTab.Today) }
                    androidx.compose.foundation.layout.Box(androidx.compose.ui.Modifier.padding(padding)) {
                        ForgeFoodPage(onBack = { select(ForgeTab.Today) }, asTab = true, viewModel = viewModel)
                    }
                }
                // No bar shows the coach as a tab any more (owner, 2026-11-21); selecting it opens the coach sheet.
                ForgeTab.Coach -> Unit
            }
        }
        }
        androidx.compose.animation.AnimatedVisibility(moreOpen && ForgeDesign.preview,
            enter = androidx.compose.animation.slideInHorizontally { it } + androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.slideOutHorizontally { it } + androidx.compose.animation.fadeOut()) {
            ForgeMoreOverlay(viewModel, onDismiss = { moreOpen = false })
        }
        // The profile photo's Settings; its search field opens the one search on the More page, as iOS's does.
        if (settingsOpen && ForgeDesign.preview) {
            ForgeOverlayPage(onDismiss = { settingsOpen = false }) {
                ForgeSettings(viewModel, onClose = { settingsOpen = false },
                              onSearch = { settingsOpen = false; ForgeDesign.focusSearch = true; moreOpen = true })
            }
        }
        // In the new design the coach sits in each main page's header and opens as a sheet, as on iOS; the floating
        // button is for the shipped tabs.
        if (coachOpen && openCoach != null) ForgeCoachSheet(viewModel, onDismiss = { coachOpen = false })
        if (!ForgeDesign.preview) ForgeCoachButton(viewModel)
    }
}
