package com.noop.ui.forge

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.noop.ui.NoopPrefs

/**
 * Fork (DX23876), Forge parity 2026-11: the "New design (preview)" switch, the twin of iOS's `ForgeDesignPrefs`.
 * Off by default, as on iOS: the shipped Forge tabs (Today, Trends, Training, Sleep, More) stay until the owner
 * decides otherwise. On, the shell shows the new design's tabs (Today with its timeline, Training, Sleep, Health,
 * and the coach in its own place). Same key as iOS, so the choice reads the same on both.
 *
 * `--ez new_design true|false` on the launch intent overrides it for emulator checks in a debug build, without
 * writing the switch, as `--new-design` does on iOS.
 */
object ForgeDesign {
    const val KEY = "noop.forgeDesign.preview"
    const val DEFAULT = false
    const val EXTRA = "new_design"

    /** Observed by the shell, so flipping the switch in Lab redraws the tabs at once. */
    var preview by mutableStateOf(DEFAULT)
        private set

    fun load(context: Context, intent: Intent? = null) {
        val prefs = context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE)
        // The launch extra is a debug-build override that leaves the stored switch alone, as iOS's `--new-design`:
        // a release build ignores it, so no other app can flip the wearer's choice through the launcher.
        val override = intent?.takeIf { com.noop.BuildConfig.DEBUG && it.hasExtra(EXTRA) }?.getBooleanExtra(EXTRA, DEFAULT)
        preview = override ?: prefs.getBoolean(KEY, DEFAULT)
        ForgeColorProfile.load(context)
        ScoreRingStyle.load(context)
        ForgeAccent.load(context)
        TodayWidgets.seedDemoIfRequested(context, intent)
        com.noop.ingest.DebugHealthConnectSeed.seedIfRequested(context, intent)
    }

    /** Set by a tab header's magnifier: the More page it opens puts the cursor in its search field, once. */
    var focusSearch by mutableStateOf(false)

    /** Set by Today's "What changed" card: the Health tab it selects opens Trends over itself, once. */
    var openTrends by mutableStateOf(false)

    fun set(context: Context, on: Boolean) {
        context.getSharedPreferences(NoopPrefs.NAME, Context.MODE_PRIVATE).edit().putBoolean(KEY, on).apply()
        preview = on
    }

    /**
     * The tabs in the bar, in order. The new design follows iOS's `RootTabView` (Today, Training, Sleep, Health, and
     * Coach while the coach is on); the shipped one keeps Trends and More. Pure, so the two rosters are tested.
     */
    fun tabs(newDesign: Boolean, coachEnabled: Boolean): List<ForgeTab> =
        if (newDesign) listOfNotNull(ForgeTab.Today, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.Health,
                                     ForgeTab.Coach.takeIf { coachEnabled })
        else listOf(ForgeTab.Today, ForgeTab.Trends, ForgeTab.Training, ForgeTab.Sleep, ForgeTab.More)
}

/**
 * In the new design everything the More tab held lives behind the profile button, as iOS's `RootTabView` puts it:
 * a tab header's profile (and Today's strap battery) open the More page over the tabs. Null in the shipped design,
 * where the profile opens Settings and More is a tab.
 */
val LocalForgeOpenMore = androidx.compose.runtime.compositionLocalOf<(() -> Unit)?> { null }

/** Opens the new design's Settings over the tabs, as iOS's profile photo does (`ForgeSettingsView`); null in the shipped design. */
val LocalForgeOpenSettings = androidx.compose.runtime.compositionLocalOf<(() -> Unit)?> { null }

/**
 * The More page over the tabs, with its own search, profile, strap and every page it lists.
 *
 * A layer of its own over the tabs, not a [ForgeOverlayPage]: the overlay host holds one page, and the pages More
 * opens (Analysis, Health & Body, Tools, Settings) are overlay pages themselves. As an overlay page More was
 * replaced by the first of them, which then lost its own caller and closed both, leaving the profile dead.
 */
@androidx.compose.runtime.Composable
internal fun ForgeMoreOverlay(viewModel: com.noop.ui.AppViewModel, onDismiss: () -> Unit) {
    androidx.compose.foundation.layout.Box(
        androidx.compose.ui.Modifier.fillMaxSize()
            // Takes every touch, so nothing reaches the tab underneath.
            .pointerInput(Unit) { awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } } }
    ) {
        ForgeSceneBackdrop(ForgeBackdrop.Sky) {
            androidx.activity.compose.BackHandler(onBack = onDismiss)
            // The system bars' insets, as the tab's Scaffold supplied them: empty padding drew the title under the clock.
            ForgeMoreScreen(WindowInsets.systemBars.asPaddingValues(), viewModel)
        }
    }
}
